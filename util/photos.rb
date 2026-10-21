#!/usr/bin/env ruby
# joshbeard.com photo album deployer
#
# This hacky script handles the 'build' and deployment of my photo albums.
#
# It does the following:
#   - Creates a file list (file_list.txt) for each album for Jekyll to use to
#     generate the pages.
#   - Removes exif data from images that still have it (using exiv2)
#   - Creates image thumbnails (using mogrify)
#   - Syncs albums to S3, setting cache-control on uploaded images
#   - Generates Gemini pages and uploads them to S3

#
# Requirements:
#   - AWS credentials should be set in the environment prior to running:
#     AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
#   - Ruby
#   - 'mogrify' from ImageMagick for thumbnail generation
#   - 'exiv2' command for removing exif data
#   - 'aws' command for S3 sync
#   - 'yaml' gem (usually included with Ruby)
#
# Usage:
#   ruby photos.rb [options] [<album_folder>] ...
#
# Options:
#   --dry-run          Show what would be done without making changes
#   --sync             Upload to S3. Cache-control is set on uploaded images.
#   --refresh-cache    Update S3 cache-control only on objects where it differs
#
# By default, the script performs only local operations:
#   - Updates album.yml with images (preserves existing entries)
#   - Removes EXIF data from images that still have it
#   - Generates thumbnails
#   - Creates Gemini pages
#
# Use --sync to also upload new or modified files to S3. Unchanged objects are
# left alone. Use --refresh-cache to repair cache-control on existing objects.
#
# Specify a path or multiple space-delimited paths to directories containing
# photos. For example:
#   ruby photos.rb photos/2022                    # Local processing only
#   ruby photos.rb --sync photos/2022               # Include S3 upload
#   ruby photos.rb --dry-run --sync photos/2022     # Preview S3 operations
#
# NOTE: An 'album.yml' file should exist in the directory prior to running
# this.
#
# SAFETY: This script will NEVER delete files from S3. It only uploads new or
# modified files. This ensures that photos uploaded previously are not
# accidentally deleted if they're not present locally.
#

require 'yaml'
require 'fileutils'
require 'optparse'
require 'open3'

# ======================================================================
# Configuration
#
# Path to the photos root directory where album sub-directories exist
PHOTO_DIR = "photos"
# Filename for the album info file created by the Jekyll plugin
ALBUM_INFO_FILENAME = "album.yml"
# Longest edge, in pixels, of generated thumbnails.
# Sized for a full-width phone column on a 3x display.
THUMB_WIDTH = 1200
THUMB_QUALITY = 75
# Path for thumbs directory relative to the album directory.
THUMB_DIR = "thumbs"
S3_BUCKET = "joshbeard.me-photos"
# Cache-Control max-age applied to image uploads, in seconds (180 days).
CACHE_MAX_AGE = 15552000
# ======================================================================

class PhotoDeployer
  @@dry_run = false
  @@sync = false
  @@refresh_cache = false

  # ANSI color codes
  COLOR_RESET = "\033[0m"
  COLOR_BOLD = "\033[1m"
  COLOR_RED = "\033[31m"
  COLOR_GREEN = "\033[32m"
  COLOR_YELLOW = "\033[33m"
  COLOR_BLUE = "\033[34m"
  COLOR_CYAN = "\033[36m"

  def self.dry_run?
    @@dry_run
  end

  def self.set_dry_run(value)
    @@dry_run = value
  end

  def self.sync?
    @@sync
  end

  def self.set_sync(value)
    @@sync = value
  end

  def self.refresh_cache?
    @@refresh_cache
  end

  def self.set_refresh_cache(value)
    @@refresh_cache = value
  end

  def self.handler(signal)
    puts "#{COLOR_RED}SIGINT or CTRL-C received. Exiting.#{COLOR_RESET}"
    exit 0
  end

  # Longest edge of an image, in pixels.
  #
  # @param path [String] The local path to an image
  # @return [Integer, nil] The longer of width and height, or nil if it cannot be read
  def self.image_long_edge(path)
    stdout, status = Open3.capture2('magick', 'identify', '-format', '%w %h', path)
    return nil unless status.success?

    width, height = stdout.split.map(&:to_i)
    return nil if width <= 0 || height <= 0

    [width, height].max
  end

  # A thumbnail needs a rebuild when it is missing, the source file is newer,
  # or its long edge is below both the target and the original. Originals
  # smaller than the target are left at their own size.
  #
  # @param original [String] The local path to the source image
  # @param thumb [String] The local path to the thumbnail
  # @return [Boolean]
  def self.thumbnail_needs_rebuild?(original, thumb)
    return true unless File.exist?(thumb)
    return true if source_replaced?(original, thumb)

    thumb_edge = image_long_edge(thumb)
    original_edge = image_long_edge(original)
    return true if thumb_edge.nil? || original_edge.nil?

    thumb_edge < [THUMB_WIDTH, original_edge].min
  end

  # Create thumbnails for images in an album directory
  #
  # Uses the 'mogrify' tool to generate thumbnails for images in an album
  # directory and places them in the 'THUMBS_DIR' within the album directory.
  # Existing thumbnails are rewritten when the source is newer or the long edge is below the target.
  #
  # @param path [String] The local path to a specific photo album directory
  def self.create_album_thumbnails(path)
    thumb_dir = File.join(path, THUMB_DIR)
    unless dry_run?
      FileUtils.mkdir_p(thumb_dir) unless Dir.exist?(thumb_dir)
    end

    image_list = list_album_images(path)
    puts "  ▸ [thumbnails] Generating thumbnails for #{path}"

    image_list.each do |image|
      photo = File.join(path, image)
      thumb_path = File.join(thumb_dir, image)
      next unless thumbnail_needs_rebuild?(photo, thumb_path)

      if dry_run?
        puts "    ▹ [DRY RUN] Would generate thumbnail: #{thumb_path}"
      else
        begin
          puts "    ▹ [thumbnails] #{image}"
          cmd = [
            '/usr/bin/env', 'mogrify',
            '-path', thumb_dir,
            '-resize', "#{THUMB_WIDTH}x#{THUMB_WIDTH}>",
            '-quality', THUMB_QUALITY.to_s,
            '-strip',
            photo
          ]
          unless system(*cmd)
            puts "    ▹ [thumbnails] Error generating thumbnail for #{photo}"
          end
        rescue => e
          puts "    ▹ [thumbnails] Error generating thumbnail for #{photo}: #{e.message}"
        end
      end
    end
  end

  # Check for EXIF data in an image
  #
  # Uses the 'exiv2' to check if an image has EXIF data. JPEG files are
  # inspected in-process first; this is the fallback when that walk fails,
  # and the check used for other formats.
  #
  # @param photo [String] The local path to a specific photo
  # @return [Boolean] Boolean specifying whether an image has EXIF data or not
  def self.check_image_exif(photo)
    cmd = ['/usr/bin/env', 'exiv2', 'pr', photo]
    system(*cmd, out: File::NULL, err: File::NULL)
  end

  # Whether a JPEG marker segment is metadata exiv2 would remove.
  #
  # APP1 carries Exif or XMP, APP13 carries IPTC, and COM is a comment.
  #
  # @param marker_code [Integer]
  # @param payload [String]
  # @return [Boolean]
  def self.jpeg_metadata_segment?(marker_code, payload)
    case marker_code
    when 0xFE
      true
    when 0xE1
      payload.start_with?("Exif\x00\x00".b) ||
        payload.start_with?("http://ns.adobe.com/xap/1.0/\x00".b)
    when 0xED
      payload.start_with?("Photoshop 3.0\x00".b)
    else
      false
    end
  end

  # Walk JPEG markers until the start of scan.
  #
  # @param path [String]
  # @return [Boolean, nil] true when metadata is present, false when the
  #   image was scanned and has none, nil when the file could not be parsed
  def self.jpeg_has_metadata?(path)
    File.open(path, 'rb') do |file|
      return nil unless file.read(2) == "\xFF\xD8".b

      loop do
        byte = file.read(1)
        return nil if byte.nil?
        next unless byte == "\xFF".b

        marker = file.read(1)
        return nil if marker.nil?
        while marker == "\xFF".b
          marker = file.read(1)
          return nil if marker.nil?
        end

        marker_code = marker.ord
        # SOS begins the compressed image. EOI ends the file. Neither carries a
        # length, and metadata segments come before them.
        return false if marker_code == 0xDA || marker_code == 0xD9
        # TEM, restart markers, and SOI have no length field.
        next if marker_code == 0x01 || (marker_code >= 0xD0 && marker_code <= 0xD8)

        length_bytes = file.read(2)
        return nil if length_bytes.nil? || length_bytes.bytesize < 2

        segment_length = length_bytes.unpack1('n')
        return nil if segment_length < 2

        payload_length = segment_length - 2
        if [0xE1, 0xED, 0xFE].include?(marker_code)
          peek_length = [payload_length, 64].min
          payload = file.read(peek_length)
          return nil if payload.nil? || payload.bytesize < peek_length

          remaining = payload_length - peek_length
          file.seek(remaining, IO::SEEK_CUR) if remaining.positive?
          return true if jpeg_metadata_segment?(marker_code, payload)
        elsif payload_length.positive?
          file.seek(payload_length, IO::SEEK_CUR)
        end
      end
    end
  end

  # Whether an image still has metadata that should be stripped.
  #
  # JPEGs are scanned in-process. A failed scan, or any other format, falls
  # back to exiv2.
  #
  # @param photo [String]
  # @return [Boolean]
  def self.image_has_metadata?(photo)
    if File.extname(photo).downcase.match?(/\.jpe?g\z/)
      detected = jpeg_has_metadata?(photo)
      return detected unless detected.nil?
    end

    check_image_exif(photo)
  rescue StandardError
    check_image_exif(photo)
  end

  # A source image is new or replaced when it has no thumbnail yet, or the
  # thumbnail was generated from an older copy of the file.
  #
  # @param original [String]
  # @param thumb [String]
  # @return [Boolean]
  def self.source_replaced?(original, thumb)
    return true unless File.exist?(thumb)

    File.mtime(original) > File.mtime(thumb)
  end

  # Remove EXIF data from images in an album
  #
  # Uses the 'exiv2' tool to remove metadata from images that still have an
  # Exif, XMP, IPTC, or comment segment. Images that already have a current
  # thumbnail are left untouched: rewriting them would change the JPEG and
  # upload the whole album. New and replaced images are stripped.
  #
  # @param path [String] The local path to an album directory
  def self.remove_image_exif(path)
    puts "  ▸ [exif] Removing exif from images in #{path}"
    image_list = list_album_images(path)
    clean = 0
    unchanged = 0

    image_list.each do |image|
      photo = File.join(path, image)
      thumb_path = File.join(path, THUMB_DIR, image)

      begin
        unless image_has_metadata?(photo)
          clean += 1
          next
        end

        unless source_replaced?(photo, thumb_path)
          unchanged += 1
          next
        end

        if dry_run?
          puts "    ▹ [DRY RUN] Would remove EXIF data from #{photo}"
        else
          puts "    ▹ [exif] #{image}"
          cmd = ['/usr/bin/env', 'exiv2', 'rm', photo]
          unless system(*cmd)
            puts "    ▹ [exif] Error removing EXIF data from #{photo}"
          end
        end
      rescue => e
        puts "Error removing exif data for #{photo}: #{e.message}"
      end
    end

    puts "    ▹ [exif] #{clean} without metadata, #{unchanged} unchanged" if (clean + unchanged).positive?
  end

  # Create a Gemini index page for each album
  #
  # This writes an 'index.gmi' file within an album directory for use on my
  # Gemini capsule. This file isn't exposed over HTTP but is available on my
  # Gemini server via the s3fuse mount.
  #
  # Uses images from album.yml as the source of truth for
  # which images to include, so it works even when images aren't present locally.
  #
  # @param album [String] The local path to an album directory
  # @param album_info [Hash] A hash of the album info from an 'album.yml' file
  # @return [String] The Gemini page as a string
  def self.create_gemini_photo_pages(album, album_info)
    # Use images as source of truth, fall back to local images
    if album_info&.key?('images') && !album_info['images'].empty?
      image_list = album_info['images'].keys.sort
    else
      image_list = list_album_images(album)
    end

    album_index = []

    album_index << "## #{album}"
    album_index << ''
    album_index << '=> / Return Home'
    album_index << '=> /photos/ Return to Photos'
    album_index << ''

    if album_info&.key?('description')
      album_index << album_info['description']
      album_index << ''
    end

    album_index << '---'
    album_index << ''

    image_list.each do |file|
      if album_info&.key?('images') && album_info['images']&.key?(file) && album_info['images'][file]
        album_index << album_info['images'][file]
      end
      album_index << "=> /#{File.join(album, file)} #{file}"
      album_index << ''
    end

    gemini_path = File.join(album, 'index.gmi')
    gemini_content = album_index.join("\n")
    unchanged = File.exist?(gemini_path) && File.read(gemini_path) == gemini_content
    if unchanged
      puts "  ▸ [gemini] Gemini index unchanged (#{image_list.length} images)"
    elsif dry_run?
      puts "  ▸ [DRY RUN] Would write Gemini index to #{gemini_path} (#{image_list.length} images)"
    else
      File.write(gemini_path, gemini_content)
      puts "  #{COLOR_GREEN}▸ [gemini] Wrote Gemini index to #{gemini_path} (#{image_list.length} images)#{COLOR_RESET}"
    end

    gemini_content
  end

  # Update album.yml with images
  #
  # This updates the 'album.yml' file to include all images in the
  # images hash. It preserves existing descriptions and adds
  # new images found locally. This serves as the source of truth for which
  # images are in the album, allowing the Jekyll plugin to generate pages
  # without requiring all image files to be present locally.
  #
  # @param path [String] The local path to an album directory
  def self.update_album_info(path)
    info_file = File.join(path, ALBUM_INFO_FILENAME)
    local_images = list_album_images(path)

    # Load existing album info or create new hash
    album_info = get_album_info(path) || {}

    # Initialize images if it doesn't exist
    album_info['images'] ||= {}

    # Get existing image descriptions (preserve ALL of them, even if not locally present)
    existing_descriptions = album_info['images'].dup || {}

    # Add any new local images that aren't already in images
    # New images are added with empty string descriptions (will be omitted from YAML output)
    new_images = []
    local_images.each do |image|
      unless existing_descriptions.key?(image)
        # Add new image - use empty string for description (cleaner YAML output)
        existing_descriptions[image] = ''
        new_images << image
      end
      # Existing images keep their descriptions (even if not locally present)
    end

    # Update album_info with merged descriptions (preserves all existing entries)
    album_info['images'] = existing_descriptions

    # Set file_list to false since we're using images as source of truth
    album_info['file_list'] = false

    # Don't update if there are no images at all (local or existing)
    if local_images.empty? && existing_descriptions.empty?
      puts "  ▸ [album_info] No images found in #{path}, skipping album.yml update"
      return
    end

    # For images without descriptions, we need to include them in the hash
    # but YAML will write them as empty strings. We'll keep them all so
    # images.keys serves as the complete list of images.
    yaml_content = album_info.to_yaml(line_width: -1)
    unchanged = File.exist?(info_file) && File.read(info_file) == yaml_content

    if unchanged
      puts "  ▸ [album_info] album.yml unchanged"
    elsif dry_run?
      puts "  ▸ [DRY RUN] Would update album.yml"
      puts "    ▹ Local images: #{local_images.length}"
      puts "    ▹ Total in images: #{existing_descriptions.length}"
      if new_images.any?
        puts "    ▹ Would add new images: #{new_images.join(', ')}"
      end
      puts "    ▹ Would preserve existing images: #{(existing_descriptions.keys - local_images).length}"
    else
      File.write(info_file, yaml_content)
      preserved_count = (existing_descriptions.keys - local_images).length
      total_images = existing_descriptions.keys.length
      images_with_descriptions = existing_descriptions.reject { |k, v| v.nil? || v.to_s.strip.empty? }.length
      puts "  #{COLOR_GREEN}▸ [album_info] Updated album.yml#{COLOR_RESET}"
      puts "    ▹ Local images: #{local_images.length}"
      puts "    ▹ Total images in images: #{total_images}"
      puts "    ▹ Images with descriptions: #{images_with_descriptions}"
      if new_images.any?
        puts "    #{COLOR_GREEN}▹ Added new images: #{new_images.join(', ')}#{COLOR_RESET}"
      end
      if preserved_count > 0
        puts "    #{COLOR_CYAN}▹ Preserved existing images (not locally present): #{preserved_count}#{COLOR_RESET}"
      end
    end
  end

  # Return list of photos in an album directory
  #
  # @param path [String] The local path to an album directory
  # @return [Array] An array of base filenames for images in an album directory
  def self.list_album_images(path)
    return [] unless Dir.exist?(path)

    image_list = Dir.entries(path).select do |file|
      !file.start_with?('.') && file.downcase.match?(/\.(jpg|jpeg|png)$/i)
    end

    image_list.sort
  end

  # Return album info
  #
  # Load album info from an 'album.yml' file
  #
  # @param path [String] The local path to an album directory
  # @return [Hash, nil] Returns YAML hash object of album info or nil
  def self.get_album_info(path)
    info_file = File.join(path, ALBUM_INFO_FILENAME)

    if File.exist?(info_file)
      begin
        YAML.load_file(info_file)
      rescue Psych::SyntaxError => e
        puts "YAML Error in #{info_file}: #{e.message}"
        nil
      end
    end
  end

  # Normalize a local path for S3 by extracting the album directory name
  #
  # Extracts everything from "photos/" onward, or if "photos" isn't in the path,
  # takes the last directory component and prepends "photos/".
  #
  # @param path [String] The local path (e.g., "src/photos/2021" or "src/photos/2021/thumbs/img.jpg")
  # @return [String] The S3 path (e.g., "photos/2021" or "photos/2021/thumbs/img.jpg")
  def self.normalize_s3_path(path)
    parts = path.split('/')

    # Find where "photos" appears in the path
    if parts.include?('photos')
      photos_index = parts.index('photos')
      # Take everything from "photos" onward
      album_path = parts[photos_index..-1].join('/')
      album_path
    else
      # No "photos" in path, take the last directory component as album name
      album_name = File.basename(path)
      "photos/#{album_name}"
    end
  end

  # Function to check whether an image exists in S3
  #
  # @param path [String] The local path to an album directory
  # @return [Boolean] A boolean specifying whether a file exists in the S3 bucket
  def self.exists_in_s3(path)
    s3_path = normalize_s3_path(path)
    cmd = ['/usr/bin/env', 'aws', 's3', 'ls', "s3://#{S3_BUCKET}/#{s3_path}"]
    system(*cmd, out: File::NULL, err: File::NULL)
  end

  # Synchronize a local album directory to S3
  #
  # SAFETY: This method does NOT use --delete flag. It only uploads new or
  # modified files. This ensures that photos uploaded previously are not
  # accidentally deleted if they're not present locally.
  #
  # @param path [String] The local path to an album directory
  def self.copy_to_s3(path)
    s3_path = normalize_s3_path(path)
    destination = "s3://#{S3_BUCKET}/#{s3_path}"
    puts " ▸ [s3-sync] Syncing #{path} to S3 (#{destination})"
    puts "    [SAFETY] Only uploading new/modified files. Remote files will NOT be deleted."

    image_cmd = [
      '/usr/bin/env', 'aws', 's3', 'sync', path, destination,
      '--acl', 'public-read',
      '--cache-control', "max-age=#{CACHE_MAX_AGE}",
      '--exclude', '*.html',
      '--exclude', '*.yml',
      '--exclude', '*.txt',
      '--exclude', '*.gmi',
      '--exclude', '.*'
    ]
    # The Gemini index changes with the album, so it is not given the long
    # image cache lifetime.
    gmi_cmd = [
      '/usr/bin/env', 'aws', 's3', 'sync', path, destination,
      '--acl', 'public-read',
      '--exclude', '*',
      '--include', 'index.gmi'
    ]

    if dry_run?
      image_cmd << '--dryrun'
      gmi_cmd << '--dryrun'
      puts "    [DRY RUN] Would sync files to S3"
    end

    system(*image_cmd)
    system(*gmi_cmd)
  end

  # Current Cache-Control value for an S3 object, or nil when it is unset.
  #
  # @param s3_key [String]
  # @return [String, nil]
  def self.s3_cache_control(s3_key)
    stdout, status = Open3.capture2(
      '/usr/bin/env', 'aws', 's3api', 'head-object',
      '--bucket', S3_BUCKET,
      '--key', s3_key,
      '--query', 'CacheControl',
      '--output', 'text'
    )
    return nil unless status.success?

    value = stdout.strip
    return nil if value.empty? || value == 'None'

    value
  end

  # Set the 'cache-control' on image objects in S3 whose header differs.
  #
  # @param path [String] The local path to an album directory
  # @param maxage [Integer] The duration in seconds for the cache max age
  def self.set_s3_object_cache(path, maxage = CACHE_MAX_AGE)
    image_list = list_album_images(path)

    if image_list.empty?
      puts "  ▸ [s3-cache] No images found, skipping cache control updates"
      return
    end

    desired = "max-age=#{maxage}"
    unchanged = 0
    updated = 0

    image_list.each do |image|
      image_file = File.join(path, image)
      s3_image_file = normalize_s3_path(image_file)
      current = s3_cache_control(s3_image_file)

      if current == desired
        unchanged += 1
        next
      end

      updated += 1
      if dry_run?
        puts "  ▸ [DRY RUN] Would set S3 object cache control for #{image_file} (#{current.inspect} -> #{desired})"
        next
      end

      puts "  ▸ [s3-cache] Setting S3 object cache control for #{image_file} (#{current.inspect} -> #{desired})"
      cmd = [
        '/usr/bin/env', 'aws', 's3', 'cp',
        "s3://#{S3_BUCKET}/#{s3_image_file}",
        "s3://#{S3_BUCKET}/#{s3_image_file}",
        '--acl', 'public-read',
        '--cache-control', desired
      ]
      system(*cmd)
    end

    puts "    ▹ [s3-cache] #{updated} updated, #{unchanged} already set"
  end

  # Parse each album
  #
  # @param path [String] The local path to an album directory
  def self.parse_album(path)
    if Dir.exist?(path)
      puts "#{COLOR_CYAN}≫ Album: #{path}#{COLOR_RESET}"
      puts "  #{COLOR_YELLOW}[DRY RUN MODE]#{COLOR_RESET}" if dry_run?

      # Load the 'album.yml' file for the album
      album_info = get_album_info(path)

      # Check if there are any images before processing
      image_list = list_album_images(path)
      if image_list.empty?
        puts "  #{COLOR_YELLOW}⚠ No images found in #{path}. Skipping processing.#{COLOR_RESET}"
        puts
        puts "--------------------------------------------------------------------------------"
        puts
        return
      end

      # Parse images (local operations)
      # Update album.yml first (before loading it for other operations)
      update_album_info(path)

      # Reload album_info after updating it
      album_info = get_album_info(path)

      remove_image_exif(path)
      create_album_thumbnails(path)
      create_gemini_photo_pages(path, album_info)

      # S3 operations (only if --sync is specified). Cache-control is set on
      # the objects sync uploads. --refresh-cache repairs headers in place.
      if sync?
        copy_to_s3(path)
      elsif !refresh_cache?
        puts "  #{COLOR_BLUE}▸ [s3-sync] Skipping S3 operations (use --sync to enable)#{COLOR_RESET}"
      end
      set_s3_object_cache(path) if refresh_cache?

      puts
      puts "--------------------------------------------------------------------------------"
      puts
    end
  end
end

if __FILE__ == $0
  # Prepare and deploy photo album directories
  #
  # Iterate over each album directory specified as an argument. If none are
  # specified, parse the directories in the PHOTO_DIR.

  Signal.trap("INT") { PhotoDeployer.handler("INT") }

  # Parse command-line options
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby photos.rb [options] [<album_folder>] ..."
    opts.on("--dry-run", "Show what would be done without making changes") do
      options[:dry_run] = true
    end
    opts.on("--sync", "Upload to S3. Cache-control is set on uploaded images") do
      options[:sync] = true
    end
    opts.on("--refresh-cache", "Update S3 cache-control only where it differs") do
      options[:refresh_cache] = true
    end
    opts.on("-h", "--help", "Prints this help") do
      puts opts
      exit
    end
  end.parse!

  # Set options
  PhotoDeployer.set_dry_run(options[:dry_run] || false)
  PhotoDeployer.set_sync(options[:sync] || false)
  PhotoDeployer.set_refresh_cache(options[:refresh_cache] || false)

  puts "#{PhotoDeployer::COLOR_CYAN}╔══════════════════════════════════════════════════════════════════════════════╗#{PhotoDeployer::COLOR_RESET}"
  puts "#{PhotoDeployer::COLOR_CYAN}                                 joshbeard.com#{PhotoDeployer::COLOR_RESET}"
  puts "#{PhotoDeployer::COLOR_CYAN}                            Photo Album Deployment#{PhotoDeployer::COLOR_RESET}"
  puts "#{PhotoDeployer::COLOR_CYAN}╚══════════════════════════════════════════════════════════════════════════════╝#{PhotoDeployer::COLOR_RESET}"
  if PhotoDeployer.dry_run?
    puts "#{PhotoDeployer::COLOR_YELLOW}⚠️  DRY RUN MODE - No changes will be made#{PhotoDeployer::COLOR_RESET}"
  end
  if PhotoDeployer.sync?
    puts "#{PhotoDeployer::COLOR_GREEN}S3 SYNC ENABLED - Will upload new or modified files to S3#{PhotoDeployer::COLOR_RESET}"
  else
    puts "#{PhotoDeployer::COLOR_BLUE}LOCAL MODE - Processing locally only (use --sync to enable S3 upload)#{PhotoDeployer::COLOR_RESET}"
  end
  if PhotoDeployer.refresh_cache?
    puts "#{PhotoDeployer::COLOR_GREEN}S3 CACHE REFRESH - Will update cache-control only where it differs#{PhotoDeployer::COLOR_RESET}"
  end
  puts
  puts "Arguments: #{ARGV.inspect}"
  puts

  if ARGV.length > 0
    ARGV.each do |album|
      puts "Parsing album #{album}"
      PhotoDeployer.parse_album(album)
    end
  else
    if Dir.exist?(PHOTO_DIR)
      Dir.entries(PHOTO_DIR).each do |album|
        next if album.start_with?('.')
        album_path = File.join(PHOTO_DIR, album)
        next unless Dir.exist?(album_path)

        puts "Parsing #{album}"
        PhotoDeployer.parse_album(album_path)
      end
    else
      puts "#{COLOR_RED}Photo directory '#{PHOTO_DIR}' not found!#{COLOR_RESET}"
      exit 1
    end
  end
end
