# frozen_string_literal: true

require 'cgi'
require 'yaml'

# Embed album photos in page content by album path and filename. Captions come
# from the album's album.yml.
#
#   {% photo 2026/IMG_1964.jpeg %}
#   {% photos 2026/IMG_1989.jpeg 2026/IMG_1975.jpeg %}
#
# An unknown album or filename fails the build.
module Jekyll
  module AlbumPhotos
    module_function

    Photo = Struct.new(:album, :filename, :description, :src, :thumb, :page_url, :alt, keyword_init: true)

    def lookup(site, ref)
      album, filename = split_ref(ref)
      images = album_images(site, album)
      unless images.key?(filename)
        raise ArgumentError, "photo tag: #{filename} is not listed in #{album}/album.yml"
      end

      description = images[filename]
      out_dir = site.config.dig('gallery', 'out_dir') || '/photos'
      thumbs = site.config.dig('gallery', 'thumbs_dir') || 'thumbs'
      ext = File.extname(filename)
      Photo.new(
        album: album,
        filename: filename,
        description: description,
        src: File.join(out_dir, album, filename),
        thumb: File.join(out_dir, album, thumbs, filename),
        page_url: File.join(out_dir, album, "#{File.basename(filename, ext)}_#{ext[1..]}.html"),
        alt: GallerySeo.plain_caption(description, album)
      )
    end

    def split_ref(ref)
      text = ref.to_s.strip
      album = File.dirname(text)
      filename = File.basename(text)
      if album == '.' || album.empty?
        raise ArgumentError, "photo tag: expected album/FILENAME, got #{text.inspect}"
      end

      [album, filename]
    end

    def cache
      @cache ||= {}
    end

    def reset_cache
      @cache = {}
    end

    def album_images(site, album)
      cache[album] ||= begin
        root = site.config.dig('gallery', 'src_dir') || 'albums'
        path = File.join(root, album, 'album.yml')
        raise ArgumentError, "photo tag: no album.yml for album #{album}" unless File.exist?(path)

        metadata = YAML.load_file(path) || {}
        images = metadata['images']
        images.is_a?(Hash) ? images : {}
      end
    end

    def caption_html(site, description)
      return '' if description.to_s.strip.empty?

      markdown = site.find_converter_instance(Jekyll::Converters::Markdown)
      markdown.convert(description.to_s).strip
    end

    def attr(text)
      CGI.escapeHTML(text.to_s)
    end
  end

  class PhotoTag < Liquid::Tag
    def initialize(tag_name, markup, tokens)
      super
      @ref = markup.strip
    end

    def render(context)
      site = context.registers[:site]
      photo = AlbumPhotos.lookup(site, @ref)
      caption = AlbumPhotos.caption_html(site, photo.description)
      html = +%(<figure class="note-photo">)
      html << %(<a href="#{AlbumPhotos.attr(photo.page_url)}">)
      html << %(<img src="#{AlbumPhotos.attr(photo.src)}" alt="#{AlbumPhotos.attr(photo.alt)}" loading="lazy" decoding="async">)
      html << %(</a>)
      html << %(<figcaption>#{caption}</figcaption>) unless caption.empty?
      html << %(</figure>)
      "\n\n#{html}\n\n"
    end
  end

  class PhotosTag < Liquid::Tag
    def initialize(tag_name, markup, tokens)
      super
      @refs = markup.split
      raise SyntaxError, 'photos tag: needs at least one album/FILENAME' if @refs.empty?
    end

    def render(context)
      site = context.registers[:site]
      html = +%(<div class="note-photos">)
      @refs.each do |ref|
        photo = AlbumPhotos.lookup(site, ref)
        html << %(<a href="#{AlbumPhotos.attr(photo.page_url)}" title="#{AlbumPhotos.attr(photo.alt)}">)
        html << %(<img src="#{AlbumPhotos.attr(photo.thumb)}" alt="#{AlbumPhotos.attr(photo.alt)}" loading="lazy" decoding="async">)
        html << %(</a>)
      end
      html << %(</div>)
      "\n\n#{html}\n\n"
    end
  end
end

Jekyll::Hooks.register(:site, :after_reset) { Jekyll::AlbumPhotos.reset_cache }

Liquid::Template.register_tag('photo', Jekyll::PhotoTag)
Liquid::Template.register_tag('photos', Jekyll::PhotosTag)
