# frozen_string_literal: true

require 'cgi'
require 'fileutils'
require 'time'
require 'yaml'

module Jekyll
  module Feed
    Entry = Struct.new(:source, :id, :url, :title, :date, :html, :image, keyword_init: true)

    module Paths
      module_function

      def absolute(site, path)
        text = path.to_s
        return text if text.match?(%r{\Ahttps?://})

        base = site.config['url'].to_s.sub(%r{/+\z}, '')
        text = "/#{text}" unless text.start_with?('/')
        "#{base}#{text}"
      end

      # Feed readers resolve relative links against the feed URL. Point site
      # links at the site itself.
      def absolutize_html(site, html)
        html.to_s.gsub(/(\s(?:href|src)=["'])(\/(?!\/)[^"']*)/i) do
          "#{Regexp.last_match(1)}#{absolute(site, Regexp.last_match(2))}"
        end
      end
    end

    class GeneratedFile < StaticFile
      def initialize(site, path, content)
        relative = path.to_s.sub(%r{\A/}, '')
        dir = File.dirname(relative)
        dir = '' if dir == '.'
        super(site, site.source, dir, File.basename(relative))
        @content = content
      end

      def modified?
        true
      end

      def write(dest)
        dest_path = destination(dest)
        FileUtils.mkdir_p(File.dirname(dest_path))
        File.write(dest_path, @content)
        true
      end
    end

    class Writer
      def initialize(site)
        @site = site
      end

      def write(entries)
        config = @site.config['feed'] || {}
        limit = config['limit'].to_i
        limit = 20 if limit <= 0
        title = config['title'] || @site.config['name'] || 'Feed'
        default_path = config['path'] || '/feed.xml'

        write_file(default_path, title, newest(entries, limit))
      end

      private

      def newest(entries, limit)
        entries.sort { |a, b| (b.date <=> a.date).nonzero? || (a.url <=> b.url) }.first(limit)
      end

      def write_file(path, title, entries)
        @site.static_files << GeneratedFile.new(@site, path, render(path, title, entries))
      end

      def render(path, title, entries)
        updated = entries.first ? entries.first.date : Time.now
        author = @site.config['name'] || title
        feed_url = Paths.absolute(@site, path)
        site_url = Paths.absolute(@site, '/')

        body = +%(<?xml version="1.0" encoding="utf-8"?>\n)
        body << %(<feed xmlns="http://www.w3.org/2005/Atom" xml:base=#{xml_attr(site_url)}>\n)
        body << %(<title>#{xml_text(title)}</title>\n)
        body << %(<link href=#{xml_attr(feed_url)} rel="self" type="application/atom+xml"/>\n)
        body << %(<link href=#{xml_attr(site_url)} rel="alternate" type="text/html"/>\n)
        body << %(<id>#{xml_text(feed_url)}</id>\n)
        body << %(<updated>#{xml_time(updated)}</updated>\n)
        body << %(<author><name>#{xml_text(author)}</name></author>\n)
        entries.each do |entry|
          body << %(<entry>\n)
          body << %(<title>#{xml_text(entry.title)}</title>\n)
          body << %(<link href=#{xml_attr(entry.url)} rel="alternate" type="text/html"/>\n)
          body << %(<id>#{xml_text(entry.id)}</id>\n)
          body << %(<updated>#{xml_time(entry.date)}</updated>\n)
          if entry.image
            body << %(<link href=#{xml_attr(entry.image)} rel="enclosure" type=#{xml_attr(mime_for(entry.image))}/>\n)
          end
          body << %(<content type="html">#{xml_text(entry.html)}</content>\n)
          body << %(</entry>\n)
        end
        body << %(</feed>\n)
        body
      end

      def xml_text(text)
        text.to_s.encode(xml: :text)
      end

      def xml_attr(text)
        text.to_s.encode(xml: :attr)
      end

      def xml_time(time)
        time.utc.iso8601
      end

      def mime_for(path)
        case File.extname(path).downcase
        when '.png' then 'image/png'
        when '.gif' then 'image/gif'
        when '.webp' then 'image/webp'
        else 'image/jpeg'
        end
      end
    end

    module Sources
      class Photos
        MONTHS = %w[january february march april may june july august september october november december].freeze
        SOURCE = 'photos'

        def entries(site)
          root = site.config.dig('gallery', 'src_dir') || 'albums'
          thumbs = site.config.dig('gallery', 'thumbs_dir') || 'thumbs'
          out_dir = site.config.dig('gallery', 'out_dir') || '/photos'
          markdown = site.find_converter_instance(Jekyll::Converters::Markdown)

          album_directories(root, thumbs).flat_map do |dir|
            entries_for_album(site, dir, out_dir, markdown)
          end
        end

        private

        def album_directories(root, thumbs)
          return [] unless File.directory?(root)

          Dir.children(root).sort.flat_map do |name|
            next [] if name.start_with?('.') || name == thumbs

            path = File.join(root, name)
            next [] unless File.directory?(path)

            found = []
            found << path if File.exist?(File.join(path, 'album.yml'))
            found.concat(album_directories(path, thumbs))
            found
          end
        end

        def entries_for_album(site, dir, out_dir, markdown)
          metadata = YAML.load_file(File.join(dir, 'album.yml')) || {}
          return [] unless metadata.is_a?(Hash)
          return [] if metadata['hidden']

          images = metadata['images']
          return [] unless images.is_a?(Hash)

          album = File.basename(dir)
          images.filter_map do |filename, description|
            date = parse_date(description)
            next if date.nil?

            page_path = File.join(out_dir, album, image_page_name(filename))
            image_path = File.join(out_dir, album, filename.to_s)
            url = Paths.absolute(site, page_path)
            title = GallerySeo.plain_caption(description, album)
            image = Paths.absolute(site, image_path)

            Entry.new(
              source: SOURCE,
              id: url,
              url: url,
              title: "Photo: #{title}",
              date: date,
              html: entry_html(site, markdown, description, image, title),
              image: image
            )
          end
        end

        def entry_html(site, markdown, description, image, title)
          img = %(<p><img src="#{CGI.escapeHTML(image)}" alt="#{CGI.escapeHTML(title)}"></p>)
          caption = Paths.absolutize_html(site, markdown.convert(description.to_s))
          img + caption
        end

        def image_page_name(filename)
          ext = File.extname(filename.to_s)
          "#{File.basename(filename.to_s, ext)}_#{ext[1..]}.html"
        end

        def parse_date(caption)
          text = caption.to_s
          if (match = text.match(/#(\d{4})-(\d{2})-(\d{2})(?:-(\d{2})(\d{2}))?/))
            return build_time(match[1], match[2], match[3], match[4], match[5])
          end

          if (match = text.match(/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2}),\s+(\d{4})\b/i))
            month = MONTHS.index(match[1].downcase)
            return nil if month.nil?

            return build_time(match[3], month + 1, match[2], nil, nil)
          end

          nil
        end

        def build_time(year, month, day, hour, minute)
          Time.utc(year.to_i, month.to_i, day.to_i, hour.to_i, minute.to_i, 0)
        rescue ArgumentError
          nil
        end
      end

      class Pages
        SKIP_TYPES = %w[image album all_photos].freeze

        def entries(site)
          markdown = site.find_converter_instance(Jekyll::Converters::Markdown)
          documents(site).filter_map { |doc| entry_for(site, doc, markdown) }
        end

        private

        def documents(site)
          docs = site.pages.dup
          site.collections.each_value { |collection| docs.concat(collection.docs) }
          docs.uniq
        end

        def entry_for(site, doc, markdown)
          data = doc.data
          return nil if SKIP_TYPES.include?(data['page_type'].to_s)

          source = source_name(data['feed'])
          return nil if source.nil?

          date = coerce_time(data['date'])
          return nil if date.nil?

          url = Paths.absolute(site, doc.url)
          title = (data['title'] || data['meta_title'] || 'Untitled').to_s
          image = data['image']
          image = image.to_s.strip.empty? ? nil : Paths.absolute(site, image)

          Entry.new(
            source: source,
            id: url,
            url: url,
            title: title,
            date: date,
            html: Paths.absolutize_html(site, markdown.convert(render_liquid(site, doc))),
            image: image
          )
        end

        # Generators run before rendering, so content still holds Liquid tags
        # such as {% photo %}.
        def render_liquid(site, doc)
          content = doc.content.to_s
          return content unless content.include?('{%') || content.include?('{{')

          payload = site.site_payload
          payload['page'] = doc.to_liquid
          Liquid::Template.parse(content)
                          .render!(payload, registers: { site: site, page: payload['page'] })
        end

        def source_name(feed)
          case feed
          when true
            'pages'
          when String
            name = feed.strip.downcase
            return 'pages' if name == 'true'
            return nil if name.empty? || name == 'false'
            return nil unless name.match?(/\A[a-z0-9][a-z0-9-]*\z/)

            name
          end
        end

        def coerce_time(value)
          case value
          when Time
            value
          when Date
            Time.utc(value.year, value.month, value.day)
          when String
            return nil if value.strip.empty?

            Time.parse(value).utc
          end
        rescue ArgumentError
          nil
        end
      end
    end
  end

  class FeedGenerator < Generator
    safe true
    priority :low

    def generate(site)
      entries = Feed::Sources::Photos.new.entries(site)
      entries.concat(Feed::Sources::Pages.new.entries(site))
      Feed::Writer.new(site).write(entries)
    end
  end
end
