module Jekyll
    module CacheBust
      class CacheDigester
        require 'digest/md5'
        attr_accessor :file_name, :directory, :source
        def initialize(file_name:, directory: nil, source: nil)
          self.file_name = file_name
          self.directory = directory
          self.source = source
        end
        def digest!
          [file_name, '?', Digest::MD5.hexdigest(file_contents)].join
        end
        private
        def source_path
          source || Dir.pwd
        end
        def resolve_path(path)
          path = path.sub(%r{^/}, '')
          File.absolute_path(path, source_path)
        end
        def directory_files_content
          target_path = File.join(resolve_path(directory), '**', '*')
          Dir[target_path].sort.map{|f| File.read(f) unless File.directory?(f) }.join
        end
        def file_content
          File.read(resolve_path(file_name))
        end
        def file_contents
          is_directory? ? directory_files_content : file_content
        end
        def is_directory?
          !directory.nil?
        end
      end
      def bust_cache(file_name)
        CacheDigester.new(file_name: file_name, directory: 'assets/css', source: @context.registers[:site].source).digest!
      end
    end
  end
  Liquid::Template.register_filter(Jekyll::CacheBust)
