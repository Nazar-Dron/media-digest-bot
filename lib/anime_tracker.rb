require 'net/http'
require 'uri'
require 'json'

module AnimeTracker
  ANILIST_URL = URI('https://graphql.anilist.co/')

  def self.search_media(title, type = 'ANIME')
    # Очищаємо українські уточнення для кращого пошуку в базі AniList
    clean_query = title.gsub(/\(.*?\)|[1-9]\s*сезон|манга/i, '').strip
    query = <<~GRAPHQL
      query ($search: String, $type: MediaType) {
        Media(search: $search, type: $type) {
          id
          episodes
          chapters
          nextAiringEpisode { episode }
        }
      }
    GRAPHQL

    res = post_graphql(query, { search: clean_query, type: type })
    media = res.dig('data', 'Media')
    return nil unless media

    current_ep = if media['nextAiringEpisode']
                   media['nextAiringEpisode']['episode'] - 1
                 else
                   (media['episodes'] || media['chapters'] || 0)
                 end

    { id: media['id'], current_ep: [current_ep, 0].max }
  end

  def self.check_all!
    DB[:anime_titles].exclude(anilist_id: nil).all.each do |anime|
      query = <<~GRAPHQL
        query ($id: Int) {
          Media(id: $id) {
            episodes
            chapters
            nextAiringEpisode { episode }
          }
        }
      GRAPHQL

      res = post_graphql(query, { id: anime[:anilist_id] })
      media = res.dig('data', 'Media')
      next unless media

      latest_ep = if media['nextAiringEpisode']
                    media['nextAiringEpisode']['episode'] - 1
                  else
                    (media['episodes'] || media['chapters'] || 0)
                  end

      if latest_ep > anime[:last_known_episode]
        ((anime[:last_known_episode] + 1)..latest_ep).each do |ep_num|
          ext_id = "anime_#{anime[:id]}_ep_#{ep_num}"
          next if DB[:queue_items].where(external_id: ext_id).any?

          watch_url = build_watch_url(anime)
          unit_label = anime[:title].downcase.include?('манга') ? 'Розділ' : 'Серія'

          DB[:queue_items].insert(
            item_type: 'anime',
            external_id: ext_id,
            source_name: anime[:title],
            title: "#{unit_label} #{ep_num}",
            url: watch_url,
            dub_info: anime[:dub_studio],
            duration_minutes: anime[:episode_duration],
            priority: anime[:priority],
            status: 'pending',
            published_at: Time.now
          )
        end

        DB[:anime_titles].where(id: anime[:id]).update(last_known_episode: latest_ep)
      end
    rescue StandardError => e
      warn "AniList error for #{anime[:title]}: #{e.message}"
    end
  end

  def self.build_watch_url(anime)
    return anime[:site_url] if anime[:site_url] && !anime[:site_url].empty?

    encoded = URI.encode_www_form_component(anime[:title])
    "https://anitube.in.ua/index.php?do=search&subaction=search&story=#{encoded}"
  end

  def self.post_graphql(query, variables)
    http = Net::HTTP.new(ANILIST_URL.host, ANILIST_URL.port)
    http.use_ssl = true
    path = ANILIST_URL.path.empty? ? '/' : ANILIST_URL.path
    req = Net::HTTP::Post.new(path, { 'Content-Type' => 'application/json' })
    req.body = { query: query, variables: variables }.to_json
    JSON.parse(http.request(req).body)
  end
end