#!/usr/bin/env ruby
# frozen_string_literal: true

# Creates a note in src/_notes.
#
#   util/new-note.rb --workout 2026-11-11-0919 [--title "Title"] [--slug slug] [--publish]
#   util/new-note.rb --workouts "2026-03-18-0655 2026-03-18-1657" --title "Title"
#   util/new-note.rb --title "Title" [--date 2026-11-12] [--slug slug] [--publish]
#
# With one workout, the date comes from the workout id, the title from its flag
# in workouts-notes.yml, and the photos from album captions that link to it.
# With several, pass a title. The date defaults to the latest workout, and the
# photos are the ones whose captions link to any of them.
#
# Notes start as drafts (published: false): not built, and their photos stay
# out of the feed until the draft is published or deleted.

require 'date'
require 'optparse'
require 'yaml'

ROOT = File.expand_path('..', __dir__)
SRC = File.join(ROOT, 'src')
NOTES_DIR = File.join(SRC, '_notes')
WORKOUT_ID = /\A(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})\z/

def fail!(message)
  warn "note: #{message}"
  exit 1
end

def plain_title(flag)
  flag.to_s.gsub(/[\p{So}\p{Sk}\p{Cf}\u{FE0F}]/, '').gsub(/\s+/, ' ').strip
end

def slugify(text)
  text.downcase.gsub(/['’]/, '').gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
end

def workout_timestamp(id)
  match = WORKOUT_ID.match(id) or fail!("workout id should look like 2026-11-11-0919, got #{id}")
  Time.new(match[1].to_i, match[2].to_i, match[3].to_i, match[4].to_i, match[5].to_i)
end

def workout_photos(workouts)
  wanted = Array(workouts)
  Dir.glob(File.join(SRC, 'photos', '**', 'album.yml')).sort.flat_map do |path|
    images = (YAML.load_file(path) || {})['images']
    next [] unless images.is_a?(Hash)

    album = File.dirname(path).delete_prefix(File.join(SRC, 'photos') + '/')
    images.select { |_, caption| wanted.any? { |workout| caption.to_s.match?(%r{/workouts/?##{Regexp.escape(workout)}\b}) } }
          .keys.map { |file| "#{album}/#{file}" }
  end.uniq.sort_by { |ref| File.basename(ref) }
end

def note_workout_ids(path)
  fm = File.read(path)[/\A---\n(.*?)\n---/m, 1]
  return [] if fm.nil?

  data = YAML.safe_load(fm, permitted_classes: [Date, Time])
  return [] unless data.is_a?(Hash)

  ids = []
  ids << data['workout'] if data['workout'].is_a?(String)
  ids.concat(data['workouts']) if data['workouts'].is_a?(Array)
  ids.map { |id| id.to_s.strip }.reject(&:empty?)
rescue Psych::SyntaxError
  []
end

def existing_note_for(workout)
  Dir.glob(File.join(NOTES_DIR, '*.md')).find do |path|
    note_workout_ids(path).include?(workout)
  end
end

options = { workouts: [] }
OptionParser.new do |opts|
  opts.banner = 'Usage: new-note.rb [--workout ID] [--workouts "ID ID"] [--title TITLE] [--date YYYY-MM-DD] [--slug SLUG] [--publish]'
  opts.on('--publish', 'Skip the draft stage') { options[:publish] = true }
  opts.on('--workout ID') { |v| options[:workouts] << v.strip }
  opts.on('--workouts IDS', 'Space-separated workout ids') { |v| options[:workouts].concat(v.split(/\s+/)) }
  opts.on('--title TITLE') { |v| options[:title] = v.strip }
  opts.on('--date DATE') { |v| options[:date] = v.strip }
  opts.on('--slug SLUG') { |v| options[:slug] = v.strip }
end.parse!

workouts = options[:workouts].map(&:strip).reject(&:empty?)
fail!('a workout id is listed more than once') if workouts.uniq.size != workouts.size
title = options[:title].to_s
date = options[:date].to_s
photos = []
short_note = nil

if workouts.any?
  workouts.each do |id|
    workout_timestamp(id)
    if (other = existing_note_for(id))
      fail!("#{File.basename(other)} is already about workout #{id}")
    end
  end

  if date.empty?
    latest = workouts.max_by { |id| workout_timestamp(id) }
    date = workout_timestamp(latest).strftime('%Y-%m-%d %H:%M')
  end

  if workouts.length == 1
    entry = (YAML.load_file(File.join(SRC, 'workouts-notes.yml')) || {})[workouts.first] || {}
    title = plain_title(entry['flag']) if title.empty?
    short_note = entry['note'].to_s.strip
    short_note = nil if short_note.empty?
  elsif title.empty?
    fail!('pass a title (TITLE="...") when a note covers more than one workout')
  end

  photos = workout_photos(workouts)
end

fail!('pass a title (TITLE="..."), or a workout with a flag in workouts-notes.yml') if title.empty?
date = Time.now.strftime('%Y-%m-%d %H:%M') if date.empty?
begin
  day = Date.parse(date).strftime('%Y-%m-%d')
rescue Date::Error
  fail!("can't read date #{date}")
end

slug = options[:slug].to_s
slug = slugify(title) if slug.empty?
fail!("can't make a slug from #{title.inspect}; pass SLUG=") if slug.empty?
path = File.join(NOTES_DIR, "#{day}-#{slug}.md")
fail!("#{path} already exists") if File.exist?(path)

front = ["title: #{title.include?(':') ? title.inspect : title}", "date: #{date}"]
if workouts.length == 1
  front << "workout: #{workouts.first}"
elsif workouts.any?
  front << 'workouts:'
  workouts.each { |id| front << "  - #{id}" }
end
front << "image: #{photos.first}" if photos.any?
front << 'published: false' unless options[:publish]

body = [short_note || 'Write something here.']
body << "{% photo #{photos.first} %}" if photos.any?
body << "{% photos #{photos.drop(1).join(' ')} %}" if photos.length > 1

Dir.mkdir(NOTES_DIR) unless Dir.exist?(NOTES_DIR)
File.write(path, "---\n#{front.join("\n")}\n---\n#{body.join("\n\n")}\n")

puts "Created #{path.delete_prefix(ROOT + '/')}"
puts "  #{photos.length} photo#{'s' unless photos.length == 1} from the albums" if workouts.any?
puts "  Draft - its photos stay out of the feed. Remove `published: false` when it's ready." unless options[:publish]
if short_note
  puts "  Started from the note in workouts-notes.yml - remove it there so the text lives in one place."
end
if workouts.any?
  when_to = options[:publish] ? 'Run' : 'Once it is published, run'
  puts "  #{when_to} healthexport to link the workout row and fill in stats and music."
end
