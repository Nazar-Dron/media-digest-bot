require 'net/http'
require 'uri'
require 'json'
require 'nokogiri'
require 'time'

module YoutubeTracker
  API_KEY = ENV.fetch('YOUTUBE_API_KEY')

  def self.resolve_channel(handle)
    clean_handle = handle.delete_prefix('@')
    uri = URI("https://www.googleapis.com/youtube/v3/channels?part=snippet&forHandle=#{URI.encode_www_form_component(clean_handle)}&key=#{API_KEY}")
    res = JSON.parse(Net::HTTP.get(uri))
    item = res['items']&.first
    return nil unless item

    { channel_id: item['id'], title: item.dig('snippet', 'title') }
  rescue StandardError => e
    warn "YouTube resolve error (#{handle}): #{e.message}"
    nil
  end

  def self.check_all!
    DB[:youtube_channels].all.each do |channel|
      next unless channel[:channel_id]

      feed_url = URI("https://www.youtube.com/feeds/videos.xml?channel_id=#{channel[:channel_id]}")
      xml = Net::HTTP.get(feed_url)
      doc = Nokogiri::XML(xml)
      doc.remove_namespaces!

      new_videos = []
      doc.xpath('//entry').each do |entry|
        published = Time.parse(entry.at_xpath('published').text)
        next if channel[:last_checked_at] && published <= channel[:last_checked_at]

        video_id = entry.at_xpath('videoId').text
        next if DB[:queue_items].where(external_id: video_id).any?

        new_videos << {
          video_id: video_id,
          title: entry.at_xpath('title').text,
          url: "https://www.youtube.com/watch?v=#{video_id}",
          published_at: published
        }
      end

      if new_videos.any?
        durations = fetch_durations(new_videos.map { |v| v[:video_id] })
        new_videos.each do |v|
          mins = durations[v[:video_id]] || 15
          next if mins < 2 # ігноруємо Shorts до 2 хв (за бажанням можна прибрати)

          DB[:queue_items].insert(
            item_type: 'youtube',
            external_id: v[:video_id],
            source_name: channel[:title] || channel[:handle],
            title: v[:title],
            url: v[:url],
            duration_minutes: mins,
            priority: channel[:priority],
            status: 'pending',
            published_at: v[:published_at]
          )
        end
      end

      DB[:youtube_channels].where(id: channel[:id]).update(last_checked_at: Time.now)
    rescue StandardError => e
      warn "RSS error for #{channel[:handle]}: #{e.message}"
    end
  end

  def self.fetch_durations(video_ids)
    uri = URI("https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=#{video_ids.join(',')}&key=#{API_KEY}")
    res = JSON.parse(Net::HTTP.get(uri))
    result = {}

    (res['items'] || []).each do |item|
      iso = item.dig('contentDetails', 'duration') # формат PT1H23M45S
      result[item['id']] = parse_iso8601_minutes(iso)
    end
    result
  end

  def self.parse_iso8601_minutes(iso)
    hours = iso[/(\d+)H/, 1].to_i
    mins  = iso[/(\d+)M/, 1].to_i
    secs  = iso[/(\d+)S/, 1].to_i
    total = (hours * 60) + mins + (secs >= 30 ? 1 : 0)
    [total, 1].max
  end
end