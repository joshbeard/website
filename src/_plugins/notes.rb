# frozen_string_literal: true

# Prepares documents in the notes collection before rendering.
#
# - image: an album reference such as 2026/IMG_1964.jpeg becomes the photo's
#   site path, and thumb is set to its thumbnail. Head tags, the feed, and the
#   notes index use these.
# - description: defaults to the first paragraph of text, for meta tags and the
#   notes index.
# - workout_ids: workout (one id) or workouts (a list) becomes one array.
#   A workout can belong to only one note.
module Jekyll
  class NotesGenerator < Generator
    safe true
    priority :high

    def generate(site)
      notes = site.collections['notes']
      return unless notes

      assign_workout_ids(notes)
      notes.docs.each do |doc|
        resolve_image(site, doc)
        doc.data['description'] ||= first_paragraph(doc.content)
      end
    end

    private

    def assign_workout_ids(notes)
      owners = {}
      notes.docs.each do |doc|
        ids = workout_ids_for(doc)
        ids.each do |id|
          if (other = owners[id])
            raise ArgumentError, "#{doc.relative_path}: workout #{id} is also in #{other}"
          end

          owners[id] = doc.relative_path
        end
        doc.data['workout_ids'] = ids
      end
    end

    def workout_ids_for(doc)
      data = doc.data
      single = data['workout']
      has_single = single.is_a?(String) && !single.strip.empty?
      if !single.nil? && !single.is_a?(String)
        raise ArgumentError, "#{doc.relative_path}: workout must be a workout id"
      end

      raw = []
      if data.key?('workouts') && !data['workouts'].nil?
        many = data['workouts']
        unless many.is_a?(Array)
          raise ArgumentError, "#{doc.relative_path}: workouts must be a list"
        end
        if has_single
          raise ArgumentError, "#{doc.relative_path}: set workout or workouts, not both"
        end

        raw = many
      elsif has_single
        raw = [single]
      end

      seen = {}
      raw.map do |id|
        id = id.to_s.strip
        raise ArgumentError, "#{doc.relative_path}: workout id is blank" if id.empty?
        raise ArgumentError, "#{doc.relative_path}: workout #{id} is listed more than once" if seen[id]

        seen[id] = true
        id
      end
    end

    def resolve_image(site, doc)
      ref = doc.data['image'].to_s.strip
      return if ref.empty? || ref.start_with?('/') || ref.match?(%r{\Ahttps?://})

      photo = AlbumPhotos.lookup(site, ref)
      doc.data['image'] = photo.src
      doc.data['thumb'] = photo.thumb
      doc.data['image_alt'] ||= photo.alt
    rescue ArgumentError => e
      raise ArgumentError, "#{doc.relative_path}: #{e.message}"
    end

    def first_paragraph(content)
      paragraph = content.to_s.split(/\n\s*\n/).map(&:strip).find do |para|
        !para.empty? && !para.start_with?('{%', '<', '#', '!')
      end
      return nil if paragraph.nil?

      text = paragraph.gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')
      text = text.gsub(/[*_`]+/, '')
      text.gsub(/\s+/, ' ').strip
    end
  end
end
