require 'dotenv/load'
require 'telegram/bot'
require 'rufus-scheduler'
require 'socket'
require_relative 'db/schema'
require_relative 'lib/youtube_tracker'
require_relative 'lib/anime_tracker'
require_relative 'lib/digest_builder'

TOKEN = ENV.fetch('TELEGRAM_BOT_TOKEN')
OWNER_ID = ENV.fetch('OWNER_CHAT_ID').to_i

# 1. Легкий HTTP-сервер для healthcheck хмарного хостингу (Render / Koyeb)
Thread.new do
  server = TCPServer.new('0.0.0.0', ENV.fetch('PORT', 8080).to_i)
  loop do
    client = server.accept
    client.print "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK"
    client.close
  rescue StandardError
    nil
  end
end

# 2. Планувальник перевірки нових відео (щогодини) та вечірньої розсилки
scheduler = Rufus::Scheduler.new

scheduler.every '1h', first_in: '10s' do
  YoutubeTracker.check_all!
  AnimeTracker.check_all!
end

def schedule_daily_job(scheduler, bot_api)
  scheduler.jobs(tag: 'daily_digest').each(&:unschedule)
  notify_time = DB[:settings].first[:notify_time] # "19:30"
  hour, min = notify_time.split(':').map(&:to_i)

  scheduler.cron "#{min} #{hour} * * *", tag: 'daily_digest' do
    YoutubeTracker.check_all!
    AnimeTracker.check_all!
    msg = DigestBuilder.build_daily_digest(mark_as_sent: true)
    if msg
      bot_api.send_message(chat_id: OWNER_ID, text: msg, parse_mode: 'HTML', disable_web_page_preview: true)
    else
      bot_api.send_message(chat_id: OWNER_ID, text: '📭 На сьогодні нових відео чи серій аніме немає.')
    end
  end
end

# 3. Обробка команд Telegram
Telegram::Bot::Client.run(TOKEN) do |bot|
  schedule_daily_job(scheduler, bot.api)
  puts 'Бот успішно запущений!'

  bot.listen do |message|
    next unless message.is_a?(Telegram::Bot::Types::Message)
    next unless message.chat.id == OWNER_ID # захист: реагує тільки на твій акаунт
    text = message.text.to_s.strip

    case text
    when '/start', '/help'
      help_text = <<~HTML
        <b>Керування трекером YouTube та Аніме:</b>

        📅 <b>Розклад та ліміти:</b>
        <code>/digest</code> — отримати добірку прямо зараз
        <code>/queue</code> — подивитися всю чергу очікування
        <code>/limit 150</code> — встановити денний ліміт у хвилинах (150 = 2.5 год)
        <code>/time 19:30</code> — змінити час щоденного повідомлення

        ▶️ <b>YouTube канали:</b>
        <code>/add_yt @username 2</code> — додати канал з пріоритетом (1-5)
        <code>/del_yt @username</code> — видалити канал зі списку

        ⛩ <b>Аніме (Anitube / UAKino):</b>
        <code>/add_anime Назва | 1 | https://anitube.in.ua/... | Озвучка</code> — додати або оновити сайт/озвучку
        <code>/del_anime Назва</code> — видалити аніме зі списку

        📋 <b>Списки:</b>
        <code>/list</code> — показати всі канали, аніме та поточні налаштування
      HTML
      bot.api.send_message(chat_id: OWNER_ID, text: help_text, parse_mode: 'HTML')

    when '/digest'
      bot.api.send_message(chat_id: OWNER_ID, text: '⏳ Перевіряю оновлення та формую список...')
      YoutubeTracker.check_all!
      AnimeTracker.check_all!
      msg = DigestBuilder.build_daily_digest(mark_as_sent: true)
      bot.api.send_message(
        chat_id: OWNER_ID,
        text: msg || '📭 Черга порожня — нових відео чи серій поки немає.',
        parse_mode: 'HTML',
        disable_web_page_preview: true
      )

    when '/queue'
      pending = DB[:queue_items].where(status: 'pending').order(Sequel.asc(:priority), Sequel.asc(:published_at)).all
      if pending.empty?
        bot.api.send_message(chat_id: OWNER_ID, text: '📭 Черга очікування порожня.')
      else
        lines = ["📦 <b>У черзі зараз (#{pending.size} шт, #{pending.sum { |i| i[:duration_minutes] }} хв):</b>\n"]
        pending.first(25).each do |i|
          lines << "• [P#{i[:priority]}] <b>#{DigestBuilder.escape_html(i[:source_name])}</b>: #{DigestBuilder.escape_html(i[:title])} (#{i[:duration_minutes]} хв)"
        end
        bot.api.send_message(chat_id: OWNER_ID, text: lines.join("\n"), parse_mode: 'HTML')
      end

    when /\A\/limit\s+(\d+)\z/
      mins = Regexp.last_match(1).to_i
      DB[:settings].update(daily_limit_minutes: mins)
      bot.api.send_message(chat_id: OWNER_ID, text: "✅ Денний ліміт оновлено: <b>#{mins} хв</b> (#{mins / 60} год #{mins % 60} хв).", parse_mode: 'HTML')

    when /\A\/time\s+(\d{1,2}:\d{2})\z/
      new_time = Regexp.last_match(1)
      DB[:settings].update(notify_time: new_time)
      schedule_daily_job(scheduler, bot.api)
      bot.api.send_message(chat_id: OWNER_ID, text: "✅ Час щоденного повідомлення змінено на <b>#{new_time}</b>.", parse_mode: 'HTML')

    when /\A\/add_yt\s+(@?[\w.-]+)(?:\s+([1-5]))?\z/
      handle = Regexp.last_match(1)
      handle = "@#{handle}" unless handle.start_with?('@')
      prio = (Regexp.last_match(2) || 3).to_i

      info = YoutubeTracker.resolve_channel(handle)
      if info
        existing = DB[:youtube_channels].where(handle: handle).first
        if existing
          DB[:youtube_channels].where(id: existing[:id]).update(priority: prio)
          bot.api.send_message(chat_id: OWNER_ID, text: "🔄 Канал <b>#{handle}</b> вже був у списку — пріоритет оновлено на <b>#{prio}</b>.", parse_mode: 'HTML')
        else
          DB[:youtube_channels].insert(
            handle: handle,
            channel_id: info[:channel_id],
            title: info[:title],
            priority: prio,
            last_checked_at: Time.now
          )
          bot.api.send_message(chat_id: OWNER_ID, text: "✅ Додано YouTube-канал: <b>#{info[:title]}</b> (#{handle}) з пріоритетом <b>#{prio}</b>.", parse_mode: 'HTML')
        end
      else
        bot.api.send_message(chat_id: OWNER_ID, text: "❌ Не вдалося знайти канал <code>#{handle}</code>. Перевір правильність @нікнейму.", parse_mode: 'HTML')
      end

    when /\A\/del_yt\s+(@?[\w.-]+)\z/
      handle = Regexp.last_match(1)
      handle = "@#{handle}" unless handle.start_with?('@')
      channel = DB[:youtube_channels].where(Sequel.ilike(:handle, handle)).first

      if channel
        DB[:youtube_channels].where(id: channel[:id]).delete
        DB[:queue_items].where(item_type: 'youtube', source_name: [channel[:title], channel[:handle]], status: 'pending').delete
        bot.api.send_message(chat_id: OWNER_ID, text: "🗑 Канал <b>#{channel[:handle]}</b> видалено зі списку (разом із його непереглянутою чергою).", parse_mode: 'HTML')
      else
        bot.api.send_message(chat_id: OWNER_ID, text: "❌ Канал <code>#{handle}</code> не знайдено у твоєму списку.", parse_mode: 'HTML')
      end

    when /\A\/add_anime\s+(.+)\z/
      parts = Regexp.last_match(1).split('|').map(&:strip)
      title = parts[0]
      prio  = (parts[1] && parts[1].match?(/\A[1-5]\z/)) ? parts[1].to_i : 1
      url   = parts[2]
      dub   = parts[3]

      existing = DB[:anime_titles].where(Sequel.ilike(:title, title)).first
      if existing
        updates = { priority: prio }
        updates[:site_url] = url if url && !url.empty?
        updates[:dub_studio] = dub if dub && !dub.empty?
        DB[:anime_titles].where(id: existing[:id]).update(updates)
        bot.api.send_message(chat_id: OWNER_ID, text: "🔄 Оновлено <b>#{existing[:title]}</b> (Пріоритет: #{prio}, Озвучка: #{dub || existing[:dub_studio] || 'не вказана'}).", parse_mode: 'HTML')
      else
        is_manga = title.downcase.include?('манга')
        anilist = AnimeTracker.search_media(title, is_manga ? 'MANGA' : 'ANIME')
        DB[:anime_titles].insert(
          title: title,
          anilist_id: anilist&.dig(:id),
          priority: prio,
          site_url: url,
          dub_studio: dub,
          episode_duration: is_manga ? 10 : 24,
          last_known_episode: anilist ? anilist[:current_ep] : 0
        )
        bot.api.send_message(chat_id: OWNER_ID, text: "✅ Додано аніме: <b>#{title}</b> (Пріоритет: #{prio}, Озвучка: #{dub || 'не вказана'}).", parse_mode: 'HTML')
      end

    when /\A\/del_anime\s+(.+)\z/
      query_title = Regexp.last_match(1).strip
      anime = DB[:anime_titles].where(Sequel.ilike(:title, query_title)).first ||
              DB[:anime_titles].where(Sequel.ilike(:title, "%#{query_title}%")).first

      if anime
        DB[:anime_titles].where(id: anime[:id]).delete
        DB[:queue_items].where(item_type: 'anime', source_name: anime[:title], status: 'pending').delete
        bot.api.send_message(chat_id: OWNER_ID, text: "🗑 Аніме <b>#{anime[:title]}</b> видалено зі списку.", parse_mode: 'HTML')
      else
        bot.api.send_message(chat_id: OWNER_ID, text: "❌ Аніме «#{query_title}» не знайдено у списку.", parse_mode: 'HTML')
      end

    when '/list'
      s = DB[:settings].first
      yt_list = DB[:youtube_channels].order(Sequel.asc(:priority)).all.map { |c| "• [P#{c[:priority]}] #{c[:handle]}" }.join("\n")
      ani_list = DB[:anime_titles].order(Sequel.asc(:priority)).all.map do |a|
        extra = [a[:dub_studio], a[:site_url] ? '🔗' : nil].compact.join(' ')
        "• [P#{a[:priority]}] #{a[:title]} #{extra.empty? ? '' : "(#{extra})"}"
      end.join("\n")

      msg = "⚙️ <b>Ліміт:</b> #{s[:daily_limit_minutes]} хв | <b>Час:</b> #{s[:notify_time]}\n\n<b>▶️ YouTube:</b>\n#{yt_list}\n\n<b>⛩ Аніме:</b>\n#{ani_list}"
      # Розбиваємо повідомлення, якщо список довгий
      msg.scan(/.{1,3800}/m).each do |chunk|
        bot.api.send_message(chat_id: OWNER_ID, text: chunk, parse_mode: 'HTML')
      end
    end
  end
end