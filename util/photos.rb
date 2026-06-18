#!/usr/bin/env ruby
# joshbeard.com photo album deployer
#
# This hacky script handles the 'build' and deployment of my photo albums.
#
# It does the following:
#   - Creates a file list (file_list.txt) for each album for Jekyll to use to
#     generate the pages.
#   - Removes exif data from images (using exiv2)
#   - Creates image thumbnails (using mogrify)
#   - Syncs albums to S3
#   - Sets the cache-control headers on the S3 objects
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
#   --sync             Upload to S3 and set cache headers (default: local processing only)
#
# By default, the script performs only local operations:
#   - Updates album.yml with images (preserves existing entries)
#   - Removes EXIF data
#   - Generates thumbnails
#   - Creates Gemini pages
#
# Use --sync to also upload to S3 and set cache headers.
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

# ======================================================================
# Configuration
#
# Path to the photos root directory where album sub-directories exist
PHOTO_DIR = "photos"
# Filename for the album info file created by the Jekyll plugin
ALBUM_INFO_FILENAME = "album.yml"
# Pixel width of thumbnails to generate
THUMB_WIDTH = 230
# Path for thumbs directory relative to the album directory.
THUMB_DIR = "thumbs"
S3_BUCKET = "joshbeard.me-photos"
# ======================================================================

class PhotoDeployer
  @@dry_run = false
  @@sync = false

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

  def self.handler(signal)
    puts "#{COLOR_RED}SIGINT or CTRL-C received. Exiting.#{COLOR_RESET}"
    exit 0
  end

  # Create thumbnails for images in an album directory
  #
  # Uses the 'mogrify' tool to generate thumbnails for images in an album
  # directory and places them in the 'THUMBS_DIR' within the album directory.
  #
  # @param path [String] The local path to a specific photo album directory
  def self.create_album_thumbnails(path)
    thumb_dir = File.join(path, THUMB_DIR)
    unless dry_run?
      FileUtils.mkdir_p(thumb_dir) unless Dir.exist?(thumb_dir)
    end

    image_list = list_album_images(path)
    puts "  ▸ [thumbnails] Generating thumbnails for #{path}"
    puts "    [DRY RUN] Would generate thumbnails" if dry_run? && image_list.any?

    image_list.each do |image|
      photo = File.join(path, image)
      thumb_path = File.join(thumb_dir, image)

      unless File.exist?(thumb_path)
        if dry_run?
          puts "    ▹ [DRY RUN] Would generate thumbnail: #{thumb_path}"
        else
          begin
            cmd = ['/usr/bin/env', 'mogrify', '-path', thumb_dir, '-resize', THUMB_WIDTH.to_s, photo]
            system(*cmd)
          rescue => e
            puts "    ▹ [thumbnails] Error generating thumbnail for #{photo}: #{e.message}"
          end
        end
      end
    end
  end

  # Check for EXIF data in an image
  #
  # Uses the 'exiv2' to check if an image has EXIF data.
  #
  # @param photo [String] The local path to a specific photo
  # @return [Boolean] Boolean specifying whether an image has EXIF data or not
  def self.check_image_exif(photo)
    cmd = ['/usr/bin/env', 'exiv2', 'pr', photo]
    system(*cmd, out: File::NULL, err: File::NULL)
  end

  # Remove EXIF data from images in an album
  #
  # Uses the 'exiv2' tool to remove all EXIF data from all images found in an
  # album directory.
  # It uses the 'check_image_exif()' function to check if an image has EXIF data
  # and will skip it if it doesn't.
  #
  # @param path [String] The local path to an album directory
  def self.remove_image_exif(path)
    puts "  ▸ [exif] Removing exif from images in #{path}"
    image_list = list_album_images(path)

    image_list.each do |image|
      photo = File.join(path, image)

      begin
        if check_image_exif(photo)
          if dry_run?
            puts "    ▹ [DRY RUN] Would remove EXIF data from #{photo}"
          else
            cmd = ['/usr/bin/env', 'exiv2', 'rm', photo]
            system(*cmd)
          end
        else
          puts "    ▹ [exif] Skipping #{photo} - no exif data found"
        end
      rescue => e
        puts "Error removing exif data for #{photo}: #{e.message}"
      end
    end
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
    if dry_run?
      puts "  ▸ [DRY RUN] Would write Gemini index to #{gemini_path} (#{image_list.length} images)"
    else
      File.write(gemini_path, album_index.join("\n"))
      puts "  #{COLOR_GREEN}▸ [gemini] Wrote Gemini index to #{gemini_path} (#{image_list.length} images)#{COLOR_RESET}"
    end

    album_index.join("\n")
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

    if dry_run?
      puts "  ▸ [DRY RUN] Would update album.yml"
      puts "    ▹ Local images: #{local_images.length}"
      puts "    ▹ Total in images: #{existing_descriptions.length}"
      if new_images.any?
        puts "    ▹ Would add new images: #{new_images.join(', ')}"
      end
      puts "    ▹ Would preserve existing images: #{(existing_descriptions.keys - local_images).length}"
    else
      # For images without descriptions, we need to include them in the hash
      # but YAML will write them as empty strings. We'll keep them all so
      # images.keys serves as the complete list of images.
      # Images with empty descriptions will appear in YAML as empty strings.

      # Write the updated YAML with proper formatting
      yaml_content = album_info.to_yaml
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
    puts " ▸ [s3-sync] Syncing #{path} to S3 (s3://#{S3_BUCKET}/#{s3_path})"
    puts "    [SAFETY] Only uploading new/modified files. Remote files will NOT be deleted."

    cmd = [
      '/usr/bin/env', 'aws', 's3', 'sync', path,
      "s3://#{S3_BUCKET}/#{s3_path}",
      '--acl', 'public-read',
      '--exclude', '*.html',
      '--exclude', '*.yml',
      '--exclude', '*.txt',
      '--exclude', '.*'
    ]

    if dry_run?
      cmd << '--dryrun'
      puts "    [DRY RUN] Would sync files to S3"
    end

    system(*cmd)
  end

  # Set the 'cache-control' on image objects in S3
  #
  # @param path [String] The local path to an album directory
  # @param maxage [Integer] The duration in seconds for the cache max age
  def self.set_s3_object_cache(path, maxage = 15552000)
    image_list = list_album_images(path)

    if image_list.empty?
      puts "  ▸ [s3-cache] No images found, skipping cache control updates"
      return
    end

    image_list.each do |image|
      image_file = File.join(path, image)
      s3_image_file = normalize_s3_path(image_file)

      if dry_run?
        puts "  ▸ [DRY RUN] Would set S3 object cache control for #{image_file} (s3://#{S3_BUCKET}/#{s3_image_file})"
      else
        puts "  ▸ [s3-cache] Setting S3 object cache control for #{image_file} (s3://#{S3_BUCKET}/#{s3_image_file})"

        cmd = [
          '/usr/bin/env', 'aws', 's3', 'cp',
          "s3://#{S3_BUCKET}/#{s3_image_file}",
          "s3://#{S3_BUCKET}/#{s3_image_file}",
          '--acl', 'public-read',
          '--cache-control', "max-age=#{maxage}"
        ]

        system(*cmd)
      end
    end
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

      # S3 operations (only if --sync is specified)
      if sync?
        copy_to_s3(path)
        set_s3_object_cache(path)
      else
        puts "  #{COLOR_BLUE}▸ [s3-sync] Skipping S3 operations (use --sync to enable)#{COLOR_RESET}"
      end

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
    opts.on("--sync", "Upload to S3 and set cache headers (default: local processing only)") do
      options[:sync] = true
    end
    opts.on("-h", "--help", "Prints this help") do
      puts opts
      exit
    end
  end.parse!

  # Set options
  PhotoDeployer.set_dry_run(options[:dry_run] || false)
  PhotoDeployer.set_sync(options[:sync] || false)

  puts "#{PhotoDeployer::COLOR_CYAN}╔══════════════════════════════════════════════════════════════════════════════╗#{PhotoDeployer::COLOR_RESET}"
  puts "#{PhotoDeployer::COLOR_CYAN}                                 joshbeard.com#{PhotoDeployer::COLOR_RESET}"
  puts "#{PhotoDeployer::COLOR_CYAN}                            Photo Album Deployment#{PhotoDeployer::COLOR_RESET}"
  puts "#{PhotoDeployer::COLOR_CYAN}╚══════════════════════════════════════════════════════════════════════════════╝#{PhotoDeployer::COLOR_RESET}"
  if PhotoDeployer.dry_run?
    puts "#{PhotoDeployer::COLOR_YELLOW}⚠️  DRY RUN MODE - No changes will be made#{PhotoDeployer::COLOR_RESET}"
  end
  if PhotoDeployer.sync?
    puts "#{PhotoDeployer::COLOR_GREEN}S3 SYNC ENABLED - Will upload to S3 and set cache headers#{PhotoDeployer::COLOR_RESET}"
  else
    puts "#{PhotoDeployer::COLOR_BLUE}LOCAL MODE - Processing locally only (use --sync to enable S3 upload)#{PhotoDeployer::COLOR_RESET}"
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
