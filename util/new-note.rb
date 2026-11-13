#!/usr/bin/env ruby
# frozen_string_literal: true

# Creates a note in src/_notes.
#
#   util/new-note.rb --workout 2026-11-11-0919 [--title "Title"] [--slug slug]
#   util/new-note.rb --title "Title" [--date 2026-11-12] [--slug slug]
#
# With a workout, the date comes from the workout id, the title from its flag in
# workouts-notes.yml, and the photos from album captions that link to it.

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

def workout_photos(workout)
  Dir.glob(File.join(SRC, 'photos', '**', 'album.yml')).sort.flat_map do |path|
    images = (YAML.load_file(path) || {})['images']
    next [] unless images.is_a?(Hash)

    album = File.dirname(path).delete_prefix(File.join(SRC, 'photos') + '/')
    images.select { |_, caption| caption.to_s.match?(%r{/workouts/?##{Regexp.escape(workout)}\b}) }
          .keys.map { |file| "#{album}/#{file}" }
  end.sort_by { |ref| File.basename(ref) }
end

def existing_note_for(workout)
  Dir.glob(File.join(NOTES_DIR, '*.md')).find do |path|
    File.read(path)[/\A---\n(.*?)\n---/m, 1].to_s.match?(/^workout:\s*["']?#{Regexp.escape(workout)}["']?\s*$/)
  end
end

options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: new-note.rb [--workout ID] [--title TITLE] [--date YYYY-MM-DD] [--slug SLUG]'
  opts.on('--workout ID') { |v| options[:workout] = v.strip }
  opts.on('--title TITLE') { |v| options[:title] = v.strip }
  opts.on('--date DATE') { |v| options[:date] = v.strip }
  opts.on('--slug SLUG') { |v| options[:slug] = v.strip }
end.parse!

workout = options[:workout].to_s
workout = nil if workout.empty?
title = options[:title].to_s
date = options[:date].to_s
photos = []
short_note = nil

if workout
  match = WORKOUT_ID.match(workout) or fail!("workout id should look like 2026-11-11-0919, got #{workout}")
  if (other = existing_note_for(workout))
    fail!("#{File.basename(other)} is already about workout #{workout}")
  end

  date = "#{match[1]}-#{match[2]}-#{match[3]} #{match[4]}:#{match[5]}" if date.empty?
  entry = (YAML.load_file(File.join(SRC, 'workouts-notes.yml')) || {})[workout] || {}
  title = plain_title(entry['flag']) if title.empty?
  short_note = entry['note'].to_s.strip
  short_note = nil if short_note.empty?
  photos = workout_photos(workout)
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
front << "workout: #{workout}" if workout
front << "image: #{photos.first}" if photos.any?

body = [short_note || 'Write something here.']
body << "{% photo #{photos.first} %}" if photos.any?
body << "{% photos #{photos.drop(1).join(' ')} %}" if photos.length > 1

Dir.mkdir(NOTES_DIR) unless Dir.exist?(NOTES_DIR)
File.write(path, "---\n#{front.join("\n")}\n---\n#{body.join("\n\n")}\n")

puts "Created #{path.delete_prefix(ROOT + '/')}"
puts "  #{photos.length} photo#{'s' unless photos.length == 1} from the albums" if workout
if short_note
  puts "  Started from the note in workouts-notes.yml - remove it there so the text lives in one place."
end
puts '  Run healthexport to link the workout row and fill in stats and music.' if workout
