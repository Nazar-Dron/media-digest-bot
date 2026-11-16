module DigestBuilder
  def self.build_daily_digest(mark_as_sent: true)
    settings = DB[:settings].first
    limit = settings[:daily_limit_minutes]

    pending = DB[:queue_items]
              .where(status: 'pending')
              .order(Sequel.asc(:priority), Sequel.asc(:published_at))
              .all

    return nil if pending.empty?

    selected = []
    remaining_minutes = limit

    pending.each do |item|
      if item[:duration_minutes] <= remaining_minutes
        selected << item
        remaining_minutes -= item[:duration_minutes]
      end
      break if remaining_minutes < 5
    end

    # Якщо найперше відео в черзі довше за весь денний ліміт — все одно видаємо його одним, щоб черга не застрягла
    if selected.empty? && pending.any?
      selected << pending.first
    end

    if mark_as_sent && selected.any?
      DB[:queue_items].where(id: selected.map { |i| i[:id] }).update(status: 'sent')
    end

    carried_over_count = pending.size - selected.size
    format_message(selected, limit, carried_over_count)
  end

  def self.format_message(items, limit, carried_over)
    total_mins = items.sum { |i| i[:duration_minutes] }
    hours = total_mins / 60
    mins  = total_mins % 60

    lines = ["🎬 <b>Добірка на сьогодні</b> (#{hours} год #{mins} хв із #{limit} хв):\n"]

    items.each_with_index do |item, idx|
      icon = item[:item_type] == 'anime' ? '⛩' : '▶️'
      dub  = item[:dub_info] && !item[:dub_info].empty? ? " | 🎙 <i>#{escape_html(item[:dub_info])}</i>" : ''
      lines << "#{idx + 1}. #{icon} <b>[P#{item[:priority]}] #{escape_html(item[:source_name])}</b> — <a href=\"#{item[:url]}\">#{escape_html(item[:title])}</a> (#{item[:duration_minutes]} хв)#{dub}"
    end

    if carried_over > 0
      lines << "\n⏳ <i>Ще #{carried_over} відео/серій залишилося в черзі та перенесено на завтра.</i>"
    end

    lines.join("\n")
  end

  def self.escape_html(text)
    text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end
end