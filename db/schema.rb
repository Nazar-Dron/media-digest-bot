require 'sequel'
require 'dotenv/load'

DB = Sequel.connect(ENV.fetch('DATABASE_URL'))

DB.create_table?(:settings) do
  primary_key :id
  Integer :daily_limit_minutes, default: 150 # 2 год 30 хв
  String :notify_time, default: '19:30'
end

DB.create_table?(:youtube_channels) do
  primary_key :id
  String :handle, unique: true, null: false   # наприклад @MrLololoshka
  String :channel_id                          # UC...
  String :title
  Integer :priority, default: 3               # 1..5
  DateTime :last_checked_at
end

DB.create_table?(:anime_titles) do
  primary_key :id
  String :title, unique: true, null: false
  Integer :anilist_id
  Integer :priority, default: 3               # 1..5
  String :site_url                            # пряме посилання на Anitube / UAKino
  String :dub_studio                          # бажана озвучка (Amanogawa, FanVoxUA тощо)
  Integer :episode_duration, default: 24      # хв (для манги One Piece = 10)
  Integer :last_known_episode, default: 0
end

DB.create_table?(:queue_items) do
  primary_key :id
  String :item_type, null: false              # 'youtube' або 'anime'
  String :external_id, unique: true, null: false # video_id або "anilist_#{id}_ep_#{ep}"
  String :source_name, null: false            # Назва каналу або аніме
  String :title, null: false                  # Назва відео або "Серія 5"
  String :url, null: false
  String :dub_info                            # Озвучка для аніме
  Integer :duration_minutes, null: false
  Integer :priority, null: false
  String :status, default: 'pending'          # 'pending' або 'sent'
  DateTime :published_at, null: false
end

DB[:settings].insert(daily_limit_minutes: 150, notify_time: '19:30') if DB[:settings].empty?