# frozen_string_literal: true

# Prepares documents in the notes collection before rendering.
#
# - image: an album reference such as 2026/IMG_1964.jpeg becomes the photo's
#   site path, and thumb is set to its thumbnail. Head tags, the feed, and the
#   notes index use these.
# - description: defaults to the first paragraph of text, for meta tags and the
#   notes index.
module Jekyll
  class NotesGenerator < Generator
    safe true
    priority :high

    def generate(site)
      notes = site.collections['notes']
      return unless notes

      notes.docs.each do |doc|
        resolve_image(site, doc)
        doc.data['description'] ||= first_paragraph(doc.content)
      end
    end

    private

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
