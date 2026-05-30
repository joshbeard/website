#!/usr/bin/env ruby
# Deploy the built site artifact to S3 and invalidate CloudFront from artifact diffs.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'set'
require 'time'
require 'tmpdir'

COLOR_RESET = "\033[0m"
COLOR_CYAN = "\033[36m"
COLOR_YELLOW = "\033[33m"
COLOR_GREEN = "\033[32m"
COLOR_RED = "\033[31m"

MANIFEST_VERSION = 1
DEFAULT_MANIFEST_KEY = '.deploy/manifest.json'
DEFAULT_S3_REGION = 'us-west-2'
DEFAULT_CF_REGION = 'us-east-1'
INVALIDATION_BATCH_SIZE = 1000

def run_command(*cmd, allow_failure: false)
  stdout, stderr, status = Open3.capture3(*cmd)
  if !status.success? && !allow_failure
    $stderr.puts "#{COLOR_RED}Command failed: #{cmd.join(' ')}#{COLOR_RESET}"
    $stderr.puts stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  [stdout, stderr, status]
end

def print_section(title)
  puts "#{COLOR_CYAN}#{title}#{COLOR_RESET}"
end

def relative_site_files(site_dir)
  Dir.chdir(site_dir) do
    Dir.glob('**/*', File::FNM_DOTMATCH).filter_map do |path|
      next if path == '.' || path == '..'
      next if File.directory?(path)
      next if path.start_with?('.git/')
      next if path.start_with?('.deploy/')

      path
    end.sort
  end
end

def cache_control_for(key)
  case key
  when %r{\Aassets/}
    'max-age=15552000'
  when /\A[^\/]+\.(?:png|ico)\z/i
    'max-age=1209600'
  when %r{\Aphotos/.+\.html\z}
    'max-age=86400'
  when /\.html\z/i
    'max-age=86400'
  when %r{\A(?:site|pgp|files|homelab|me|now|uses)/}
    'max-age=86400'
  end
end

def build_manifest(site_dir)
  files = {}

  relative_site_files(site_dir).each do |key|
    file_path = File.join(site_dir, key)
    files[key] = {
      'sha256' => Digest::SHA256.file(file_path).hexdigest,
      'size' => File.size(file_path),
      'cache_control' => cache_control_for(key)
    }
  end

  {
    'version' => MANIFEST_VERSION,
    'generated_at' => Time.now.utc.iso8601,
    'files' => files
  }
end

def load_manifest_file(path)
  return empty_manifest unless path && File.exist?(path)

  manifest = JSON.parse(File.read(path))
  normalize_manifest(manifest)
rescue JSON::ParserError => e
  $stderr.puts "#{COLOR_RED}Error: invalid manifest #{path}: #{e.message}#{COLOR_RESET}"
  exit 1
end

def empty_manifest
  {
    'version' => MANIFEST_VERSION,
    'generated_at' => nil,
    'files' => {}
  }
end

def normalize_manifest(manifest)
  manifest['files'] ||= {}
  manifest
end

def manifest_s3_uri(bucket, manifest_key)
  "s3://#{bucket}/#{manifest_key}"
end

def download_previous_manifest(bucket, manifest_key, region)
  temp_path = File.join(Dir.tmpdir, "deploy-site-previous-manifest-#{$$}.json")
  stdout, stderr, status = run_command(
    'aws', 's3', 'cp',
    manifest_s3_uri(bucket, manifest_key),
    temp_path,
    '--region', region,
    allow_failure: true
  )

  return load_manifest_file(temp_path) if status.success?

  missing_manifest = stderr.match?(/404|NoSuchKey|Not Found/i) || stdout.match?(/404|NoSuchKey|Not Found/i)
  unless missing_manifest
    $stderr.puts "#{COLOR_RED}Error: failed to download previous deploy manifest#{COLOR_RESET}"
    $stderr.puts stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  puts "#{COLOR_YELLOW}No previous deploy manifest found; first run will upload all artifact files.#{COLOR_RESET}"
  empty_manifest
ensure
  FileUtils.rm_f(temp_path) if temp_path
end

def diff_manifests(previous_manifest, current_manifest)
  previous_files = previous_manifest.fetch('files', {})
  current_files = current_manifest.fetch('files', {})

  uploads = []
  metadata_updates = []
  deletes = []

  current_files.each do |key, current|
    previous = previous_files[key]

    if previous.nil?
      uploads << key
    elsif previous['sha256'] != current['sha256'] || previous['size'] != current['size']
      uploads << key
    elsif previous['cache_control'] != current['cache_control']
      metadata_updates << key
    end
  end

  previous_files.each_key do |key|
    deletes << key unless current_files.key?(key)
  end

  {
    uploads: uploads.sort,
    metadata_updates: metadata_updates.sort,
    deletes: deletes.sort
  }
end

def print_diff(diff)
  print_section('Artifact diff')
  puts "  Uploads: #{diff[:uploads].length}"
  puts "  Metadata updates: #{diff[:metadata_updates].length}"
  puts "  Deletes: #{diff[:deletes].length}"
end

def aws_s3_cp_args(source, destination, region, cache_control: nil)
  args = ['aws', 's3', 'cp', source, destination, '--acl', 'public-read', '--region', region]
  args += ['--cache-control', cache_control] if cache_control
  args
end

def upload_file(site_dir, bucket, key, file_manifest, region, dry_run)
  source = File.join(site_dir, key)
  destination = "s3://#{bucket}/#{key}"
  cache_control = file_manifest['cache_control']

  puts "  upload #{key}"
  return if dry_run

  run_command(*aws_s3_cp_args(source, destination, region, cache_control: cache_control))
end

def delete_file(bucket, key, region, dry_run)
  puts "  delete #{key}"
  return if dry_run

  run_command('aws', 's3', 'rm', "s3://#{bucket}/#{key}", '--region', region)
end

def write_manifest(bucket, manifest_key, current_manifest, region, dry_run, write_manifest_path)
  manifest_json = "#{JSON.pretty_generate(current_manifest)}\n"
  File.write(write_manifest_path, manifest_json) if write_manifest_path

  puts "  write #{manifest_key}"
  return if dry_run

  temp_path = File.join(Dir.tmpdir, "deploy-site-current-manifest-#{$$}.json")
  File.write(temp_path, manifest_json)

  run_command(
    'aws', 's3', 'cp',
    temp_path,
    manifest_s3_uri(bucket, manifest_key),
    '--cache-control', 'no-store',
    '--region', region
  )
ensure
  FileUtils.rm_f(temp_path) if temp_path
end

def deploy_changes(site_dir, bucket, current_manifest, diff, region, dry_run)
  files = current_manifest.fetch('files')

  print_section(dry_run ? 'Planned S3 changes' : 'Applying S3 changes')

  (diff[:uploads] + diff[:metadata_updates]).each do |key|
    upload_file(site_dir, bucket, key, files.fetch(key), region, dry_run)
  end

  diff[:deletes].each do |key|
    delete_file(bucket, key, region, dry_run)
  end
end

def invalidation_paths_for(keys)
  paths = Set.new

  keys.each do |key|
    paths << "/#{key}"

    if key == 'index.html'
      paths << '/'
    elsif key.end_with?('/index.html')
      pretty_path = "/#{key.sub(%r{/index\.html\z}, '')}"
      paths << pretty_path
      paths << "#{pretty_path}/"
    end
  end

  paths.to_a.sort
end

def invalidate_cloudfront(paths, distribution, region, dry_run)
  if paths.empty?
    puts "#{COLOR_YELLOW}No CloudFront paths to invalidate.#{COLOR_RESET}"
    return
  end

  if distribution.to_s.empty?
    puts "#{COLOR_YELLOW}CF_DISTRIBUTION is not set; skipping CloudFront invalidation.#{COLOR_RESET}"
    return
  end

  print_section(dry_run ? 'Planned CloudFront invalidation' : 'Invalidating CloudFront')
  paths.each { |path| puts "  #{path}" }

  return if dry_run

  paths.each_slice(INVALIDATION_BATCH_SIZE) do |batch|
    stdout, stderr, status = run_command(
      'aws', 'cloudfront', 'create-invalidation',
      '--distribution-id', distribution,
      '--paths', *batch,
      '--region', region,
      '--output', 'json',
      allow_failure: true
    )

    unless status.success?
      $stderr.puts "#{COLOR_RED}Error: failed to create CloudFront invalidation#{COLOR_RESET}"
      $stderr.puts stderr unless stderr.empty?
      exit status.exitstatus || 1
    end

    invalidation_id = JSON.parse(stdout).dig('Invalidation', 'Id')
    puts "#{COLOR_GREEN}Invalidation created: #{invalidation_id}#{COLOR_RESET}" if invalidation_id
  end
end

def parse_options
  options = {
    site_dir: '.',
    bucket: ENV['AWS_S3_BUCKET'],
    manifest_key: ENV.fetch('DEPLOY_MANIFEST_KEY', DEFAULT_MANIFEST_KEY),
    s3_region: ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'] || DEFAULT_S3_REGION,
    cf_region: ENV['CF_REGION'] || DEFAULT_CF_REGION,
    cf_distribution: ENV['CF_DISTRIBUTION'],
    dry_run: false,
    previous_manifest: nil,
    write_manifest: nil
  }

  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby util/deploy-site.rb [options]'

    opts.on('--site-dir DIR', 'Built site artifact directory') { |value| options[:site_dir] = value }
    opts.on('--bucket BUCKET', 'S3 bucket name') { |value| options[:bucket] = value }
    opts.on('--manifest-key KEY', 'S3 key for the deploy manifest') { |value| options[:manifest_key] = value }
    opts.on('--s3-region REGION', 'AWS region for S3 commands') { |value| options[:s3_region] = value }
    opts.on('--cf-region REGION', 'AWS region for CloudFront commands') { |value| options[:cf_region] = value }
    opts.on('--cf-distribution ID', 'CloudFront distribution ID') { |value| options[:cf_distribution] = value }
    opts.on('--previous-manifest PATH', 'Use a local previous manifest instead of S3') { |value| options[:previous_manifest] = value }
    opts.on('--write-manifest PATH', 'Write the current manifest to a local path') { |value| options[:write_manifest] = value }
    opts.on('--dry-run', 'Print planned changes without writing to AWS') { options[:dry_run] = true }
  end.parse!

  options
end

def validate_options(options)
  unless Dir.exist?(options[:site_dir])
    $stderr.puts "#{COLOR_RED}Error: site directory not found: #{options[:site_dir]}#{COLOR_RESET}"
    exit 1
  end

  if options[:bucket].to_s.empty? && (!options[:dry_run] || options[:previous_manifest].nil?)
    $stderr.puts "#{COLOR_RED}Error: AWS_S3_BUCKET or --bucket is required#{COLOR_RESET}"
    exit 1
  end
end

def main
  options = parse_options
  validate_options(options)

  site_dir = File.expand_path(options[:site_dir])
  current_manifest = build_manifest(site_dir)
  previous_manifest = if options[:previous_manifest]
                        load_manifest_file(options[:previous_manifest])
                      else
                        download_previous_manifest(options[:bucket], options[:manifest_key], options[:s3_region])
                      end

  diff = diff_manifests(previous_manifest, current_manifest)
  print_diff(diff)

  deploy_changes(site_dir, options[:bucket], current_manifest, diff, options[:s3_region], options[:dry_run])
  write_manifest(
    options[:bucket],
    options[:manifest_key],
    current_manifest,
    options[:s3_region],
    options[:dry_run],
    options[:write_manifest]
  )

  touched_keys = diff[:uploads] + diff[:metadata_updates] + diff[:deletes]
  invalidate_cloudfront(
    invalidation_paths_for(touched_keys),
    options[:cf_distribution],
    options[:cf_region],
    options[:dry_run]
  )
end

main if $PROGRAM_NAME == __FILE__
