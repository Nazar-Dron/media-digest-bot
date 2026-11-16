require_relative 'schema'
require_relative '../lib/youtube_tracker'
require_relative '../lib/anime_tracker'

def parse_priority_file(filepath)
  current_priority = 3
  items = []

  File.readlines(filepath, chomp: true).each do |line|
    clean = line.strip
    next if clean.empty?

    if clean.match?(/\A[1-5]\z/)
      current_priority = clean.to_i
    else
      items << { name: clean, priority: current_priority }
    end
  end
  items
end

puts 'Імпорт YouTube каналів...'
parse_priority_file('yt.txt').each do |entry|
  handle = entry[:name].start_with?('@') ? entry[:name] : "@#{entry[:name]}"
  next if DB[:youtube_channels].where(handle: handle).any?

  info = YoutubeTracker.resolve_channel(handle)
  if info
    DB[:youtube_channels].insert(
      handle: handle,
      channel_id: info[:channel_id],
      title: info[:title],
      priority: entry[:priority],
      last_checked_at: Time.now
    )
    puts "  [+] #{handle} (#{info[:title]}) -> пріоритет #{entry[:priority]}"
  else
    puts "  [!] Не вдалося знайти канал: #{handle}"
  end
end

puts "\nІмпорт аніме..."
parse_priority_file('ani.txt').each do |entry|
  next if DB[:anime_titles].where(title: entry[:name]).any?

  is_manga = entry[:name].downcase.include?('манга')
  duration = is_manga ? 10 : 24
  anilist = AnimeTracker.search_media(entry[:name], is_manga ? 'MANGA' : 'ANIME')

  DB[:anime_titles].insert(
    title: entry[:name],
    anilist_id: anilist ? anilist[:id] : nil,
    priority: entry[:priority],
    episode_duration: duration,
    last_known_episode: anilist ? anilist[:current_ep] : 0
  )
  puts "  [+] #{entry[:name]} (ID: #{anilist&.dig(:id) || 'ручний'}, поточна серія: #{anilist&.dig(:current_ep) || 0}) -> пріоритет #{entry[:priority]}"
end

puts "\nГотово!"