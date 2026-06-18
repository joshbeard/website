#
#                                  Image Gallery
#                                  =============
#
# Usage:
# ======
#   Configuration (_config.yml):
#   ----------------------------
#     The relative path to the photo sources. Sub-directories of this location
#     are albums.
#     gallery.src_dir: photos
#
#     The root of the URL to serve from (www.mysite.com/<foo>/<album>)
#     gallery.out_dir: /photos
#
#     The path where thumbs are located. This is expected to be a sub-directory
#     of the album.
#     gallery.thumbs_dir: thumbs
#
#   Album Configuration:
#   --------------------
#     album.yml
#       This file may contain metadata about the album using the following keys:
#       description : str, optional
#           A description of the album (string)
#       meta_description : str, optional
#           A description of the album to use in the page headers and metadata (string)
#       images : dict, optional
#           A hash of key/value pairs where the key is a filename and the value is
#           a description for an image. If this key exists, the plugin will use
#           the keys from this hash as the list of images in the album, allowing
#           the Jekyll build to run without the image files present - they are
#           not in Git.
#       key_image : str, optional
#           An optional filename of an image to use for the album
#           thumbnail. If none is specified, the first image is used.
#       keywords : list, optional
#           A list of keywords to add to the HTML page meta
#
# This was adapted from https://github.com/kylemarsh/jekyll-gallery-generator
#
# Modifications:
#   - key_image
#   - image descriptions
#   - customize output directory
#
# The MIT License (MIT)
#
# Copyright (c) 2014 Kyle Marsh
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
module Jekyll
  class ImagePage < Page
    # An image page
    def initialize(site, base, outdir, img_source, thumb, album_name, name, prev_name, next_name, album_page, description)
      @site = site
      @base = base
      @dir = outdir
      @name = File.basename(name) # Name of the generated page

      self.process(@name)
      self.read_yaml(File.join(@base, '_layouts'), 'image_page.html')
      self.data['title'] = File.basename(img_source).to_s()
      self.data['img_src'] = img_source
      self.data['thumb'] = thumb
      self.data['prev_url'] = prev_name
      self.data['next_url'] = next_name
      self.data['album_url'] = album_page
      self.data['album_name'] = album_name
      self.data['description'] = description
    end
  end

  class AlbumPage < Page
    # An album page

    DEFAULT_METADATA = {
      'sort' => 'filename asc',
      'paginate' => 100,
    }

    def initialize(site, base, dir, outdir, page=0)
      @site = site
      @base = base # Absolute path to use to find files for generation

      # Page will be created at www.mysite.com/#{dir}/#{name}
      @dir = File.join(site.config['gallery']['out_dir'] || 'albums', outdir)
      @name = album_name_from_page(page)

      @album_source = File.join(site.config['gallery']['src_dir'] || 'albums', dir)
      @album_metadata = get_album_metadata

      @album_name = dir.to_s()

      @thumbs_dir = site.config['gallery']['thumbs_dir'] || 'thumbs'

      self.process(@name)
      self.read_yaml(File.join(@base, '_layouts'), 'album_index.html')

      self.data['title'] = @album_metadata['meta_title'] || dir
      self.data['images'] = []
      self.data['albums'] = []
      self.data['description'] = @album_metadata['description']
      self.data['meta_description'] = @album_metadata['meta_description'] || False
      self.data['hidden'] = true if @album_metadata['hidden']
      self.data['keywords'] = @album_metadata['keywords'] || []

      files, directories = list_album_contents

      # Use images from album.yml as source of truth if available
      # This allows building without image files present locally
      if @album_metadata['images'] && @album_metadata['images'].is_a?(Hash) && !@album_metadata['images'].empty?
        files = @album_metadata['images'].keys
      end

      #Pagination
      num_images = @album_metadata['paginate']
      if num_images
        first = num_images * page
        last = num_images * page + num_images
        self.data['prev_url'] = album_name_from_page(page-1) if page > 0
        self.data['next_url'] = album_name_from_page(page+1) if last < files.length
      end

      if page == 0
        directories.each do |subalbum|
          albumpage = AlbumPage.new(site, site.source, File.join(dir, subalbum), @dir)
          unless albumpage.data['hidden']
            self.data['albums'] << { 'name' => subalbum, 'url' => albumpage.url }
          end
          site.pages << albumpage #FIXME: sub albums are getting included in my gallery index
        end
      end

      files.each_with_index do |filename, idx|
        if num_images
          next if idx < first
          if idx >= last
            site.pages << AlbumPage.new(site, base, dir, @dir, page + 1)
            break
          end
        end
        prev_file = files[idx-1] unless idx == 0
        next_file = files[idx+1] || nil

        album_page = "#{@dir}/#{album_name_from_page(page)}"
          do_image(filename, prev_file, next_file, album_page, @album_metadata['images'])
      end
    end

    def get_album_metadata
      site_metadata = @site.config['album_config'] || {}
      local_config = {}
      config_file = File.join(@album_source, 'album.yml')
      if File.exist? config_file
        local_config = YAML.load_file(config_file)
      end
      return DEFAULT_METADATA.merge(site_metadata).merge(local_config)
    end

    def album_name_from_page(page)
      return page == 0 ? 'index.html' : "index#{page + 1}.html"
    end

    def list_album_contents
      entries = Dir.entries(@album_source)
      entries.reject! { |x| x =~ /^(\.|#{@thumbs_dir})/ } # Filter out ., .., and dotfiles

        files = entries.reject { |x| File.directory? File.join(@album_source, x) } # Filter out directories
      directories = entries.select { |x| File.directory? File.join(@album_source, x) } # Filter out non-directories

      files.select! { |x| ['.png', '.jpg', '.jpeg', '.gif'].include? File.extname(File.join(@album_source, x)) } # Filter out files that image-tag doesn't handle

      # Sort images
      def filename_sort(a, b, reverse)
        if reverse =~ /^desc/
            return b <=> a
        end
        return a <=> b
      end

      sort_on, sort_direction = @album_metadata['sort'].split
      files.sort! { |a, b| send("#{sort_on}_sort", a, b, sort_direction) }

      return files, directories
    end

    def do_image(filename, prev_file, next_file, album_page, descriptions)
      # Get info for the album page and make the image's page.

      page_link = image_page_url(filename)
      page_link = File.join(@dir, page_link).to_s()

      img_source = File.join(@dir, filename).to_s()
      thumb = File.join(@dir, @thumbs_dir, filename).to_s()

      description = nil
      if descriptions.class == Hash
        if descriptions.key?(filename)
          description = descriptions[filename]
        end
      end

      image_data = {
        'src' => img_source,
        'rel_link' => page_link,
        'thumb' => thumb,
        'description' => description
      }

      self.data['images'] << image_data

      if @album_metadata.key?('key_image')
        if @album_metadata['key_image'] == filename
          self.data['key_image_data'] = image_data
        end
      end

      # Create image page
      site.pages << ImagePage.new(@site, @base, @dir, img_source, thumb, @album_name,
                                  page_link, image_page_url(prev_file), image_page_url(next_file), album_page, description)
    end

    def image_page_url(filename)
      return nil if filename.nil?
      ext = File.extname(filename)
      return "#{File.basename(filename, ext)}_#{File.extname(filename)[1..-1]}.html"
    end
  end

  class AllPhotosPage < Page
    # A flat index of all album images
    def initialize(site, base, outdir, images, all_photos_config)
      @site = site
      @base = base
      @dir = File.join(site.config['gallery']['out_dir'] || 'albums', outdir)
      @name = 'index.html'

      self.process(@name)
      self.read_yaml(File.join(@base, '_layouts'), 'all_photos_index.html')

      self.data['title'] = 'All Photos'
      self.data['images'] = images
      self.data['group_by_album'] = all_photos_config['group_by_album']
      self.data['page_type'] = 'all_photos'
    end
  end

  class GalleryGenerator < Generator
    safe true

    DEFAULT_ALL_PHOTOS_CONFIG = {
      'enabled' => false,
      'path' => 'all',
      'sort' => 'album desc',
      'group_by_album' => true,
    }

    def generate(site)
      if site.layouts.key? 'album_index'
        base_album_path = site.config['gallery']['src_dir'] || 'albums'
        albums = Dir.entries(base_album_path)
        albums.reject! { |x| x =~ /^\./ }
        albums.select! { |x| File.directory? File.join(base_album_path, x) }
        albums.each do |album|
          site.pages << AlbumPage.new(site, site.source, album, album)
        end

        generate_all_photos(site, base_album_path, albums)
      end
    end

    def generate_all_photos(site, base_album_path, albums)
      all_photos_config = all_photos_config(site)
      return unless all_photos_config['enabled']
      return unless site.layouts.key? 'all_photos_index'

      all_photos = collect_all_photos(site, base_album_path, albums, all_photos_config)
      all_path = all_photos_config['path']
      all_page_url = File.join(site.config['gallery']['out_dir'] || 'albums', all_path, 'index.html').to_s()

      all_photos.each_with_index do |photo, idx|
        prev_photo = all_photos[idx - 1] unless idx == 0
        next_photo = all_photos[idx + 1] || nil

        site.pages << ImagePage.new(site, site.source, File.dirname(photo['rel_link']), photo['src'], photo['thumb'],
                                    'All Photos', photo['rel_link'], prev_photo && prev_photo['rel_link'],
                                    next_photo && next_photo['rel_link'], all_page_url, photo['description'])
      end

      site.pages << AllPhotosPage.new(site, site.source, all_path, all_photos, all_photos_config)
    end

    def collect_all_photos(site, base_album_path, albums, all_photos_config)
      album_paths = expand_album_paths(base_album_path, albums, site.config['gallery']['thumbs_dir'] || 'thumbs')
      sort_on, sort_direction = all_photos_config['sort'].to_s.split
      album_paths.sort!
      album_paths.reverse! if sort_on == 'album' && sort_direction =~ /^desc/

      album_paths.each_with_object([]) do |album, photos|
        album_source = File.join(base_album_path, album)
        metadata = album_metadata(site, album_source)
        next if metadata['hidden']

        files = album_files(album_source, metadata, site.config['gallery']['thumbs_dir'] || 'thumbs')
        files.reverse! if sort_on == 'album' && sort_direction =~ /^desc/

        files.each do |filename|
          photos << all_photo_data(site, album, filename, metadata, all_photos_config['path'])
        end
      end
    end

    def expand_album_paths(base_album_path, albums, thumbs_dir)
      albums.each_with_object([]) do |album, paths|
        album_source = File.join(base_album_path, album)
        paths << album

        subalbums = Dir.entries(album_source)
        subalbums.reject! { |x| x =~ /^(\.|#{thumbs_dir})/ }
        subalbums.select! { |x| File.directory? File.join(album_source, x) }
        paths.concat(expand_album_paths(base_album_path, subalbums.map { |subalbum| File.join(album, subalbum) }, thumbs_dir))
      end
    end

    def album_metadata(site, album_source)
      site_metadata = site.config['album_config'] || {}
      local_config = {}
      config_file = File.join(album_source, 'album.yml')
      if File.exist? config_file
        local_config = YAML.load_file(config_file)
      end
      return AlbumPage::DEFAULT_METADATA.merge(site_metadata).merge(local_config)
    end

    def album_files(album_source, metadata, thumbs_dir)
      if metadata['images'] && metadata['images'].is_a?(Hash) && !metadata['images'].empty?
        return metadata['images'].keys
      end

      entries = Dir.entries(album_source)
      entries.reject! { |x| x =~ /^(\.|#{thumbs_dir})/ }
      files = entries.reject { |x| File.directory? File.join(album_source, x) }
      files.select! { |x| ['.png', '.jpg', '.jpeg', '.gif'].include? File.extname(File.join(album_source, x)) }

      sort_on, sort_direction = metadata['sort'].split
      files.sort! { |a, b| send("#{sort_on}_sort", a, b, sort_direction) }
      files
    end

    def filename_sort(a, b, reverse)
      if reverse =~ /^desc/
        return b <=> a
      end
      return a <=> b
    end

    def all_photo_data(site, album, filename, metadata, all_path)
      gallery_out_dir = site.config['gallery']['out_dir'] || 'albums'
      thumbs_dir = site.config['gallery']['thumbs_dir'] || 'thumbs'
      description = nil

      if metadata['images'].class == Hash && metadata['images'].key?(filename)
        description = metadata['images'][filename]
      end

      {
        'src' => File.join(gallery_out_dir, album, filename).to_s(),
        'rel_link' => File.join(gallery_out_dir, all_path, album, image_page_url(filename)).to_s(),
        'thumb' => File.join(gallery_out_dir, album, thumbs_dir, filename).to_s(),
        'description' => description,
        'album' => album,
        'album_title' => metadata['meta_title'] || album,
        'album_url' => File.join(gallery_out_dir, album, 'index.html').to_s(),
      }
    end

    def image_page_url(filename)
      return nil if filename.nil?
      ext = File.extname(filename)
      return "#{File.basename(filename, ext)}_#{File.extname(filename)[1..-1]}.html"
    end

    def all_photos_config(site)
      DEFAULT_ALL_PHOTOS_CONFIG.merge((site.config['gallery'] || {})['all_photos'] || {})
    end
  end
end
