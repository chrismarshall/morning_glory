require 'stringio'
require 'zlib'
require File.dirname(__FILE__) + "/../morning_glory"

namespace :morning_glory do
  namespace :cloudfront do

    @@prev_cdn_revision = nil
    @@scm_commit_required = false
    
    begin
      MORNING_GLORY_CONFIG = YAML.load_file("#{RAILS_ROOT}/config/morning_glory.yml") if !defined? MORNING_GLORY_CONFIG
    rescue
    end
  
    def check_config
      if !defined? MORNING_GLORY_CONFIG[Rails.env] || MORNING_GLORY_CONFIG[Rails.env]['enabled'] != true
          raise "Deployment appears to be disabled for this environment (#{Rails.env}) within config/morning_glory.yml. Specify an alternative environment with RAILS_ENV={environment name}."
      end
      if !defined? S3_CONFIG[Rails.env]
        raise "You seem to be lacking your Amazon S3 configuration file, config/s3.yml"
      end
    end
    
    def get_revision
      rev = nil

      # GIT
      begin
        git_rev = `git show --pretty=format:"%H|%ci" --quiet`.split('|')[0]
        if !git_rev.nil?
          rev = git_rev.to_s
          puts '* Using Git revision'
        end
      rescue
        # Ignore
      end
      # SVN
      begin
        svn_rev = `svnversion .`.chomp.gsub(':','_')
        puts svn_rev
        if svn_rev != 'exported' && svn_rev != '' && svn_rev != nil
          rev = Digest::MD5.hexdigest( svn_rev ).to_s
          puts '* Using SVN revision'
        end
      rescue
        # Ignore
      end
      
      if rev.nil?
        rev = Time.new.strftime("%Y%m%d%H%M%S") 
        puts '* Using timestamp revision'
        @@scm_commit_required = true
      end
      
      return rev
    end

    def update_revision
      prev = MORNING_GLORY_CONFIG[Rails.env]['revision'].to_s

      rev = get_revision
      
      MORNING_GLORY_CONFIG[Rails.env]['revision'] = rev
      ENV['RAILS_ASSET_ID'] = CLOUDFRONT_REVISION_PREFIX + rev
    
      # Store the previous revision so we can delete the bucket from S3 later after deploy
      @@prev_cdn_revision = CLOUDFRONT_REVISION_PREFIX + prev
    
      File.open("#{RAILS_ROOT}/config/morning_glory.yml", 'w') { |f| YAML.dump(MORNING_GLORY_CONFIG, f) }
    
      puts "* CDN revision updated for '#{Rails.env}' environment to #{ENV['RAILS_ASSET_ID']}" 
    end

    def compile_sass_if_available
      if defined? Sass
        puts "* Compiling Sass stylesheets"
        Sass::Plugin.update_stylesheets
      end
    end

    def upload_to_s3(upload_bucket, gzip = false)
      puts "* Attempting to create S3 Bucket '#{upload_bucket}'"
      AWS::S3::Bucket.create(upload_bucket)

      AWS::S3::Bucket.enable_logging_for(upload_bucket) if S3_LOGGING_ENABLED

      puts "* Uploading files to S3 Bucket '#{upload_bucket}'"
      DIRECTORIES.each do |directory|
        Dir[File.join(TEMP_DIRECTORY, directory, '**', "*.{#{CONTENT_TYPES.keys.join(',')}}")].each do |file|
          file_path = file.gsub(/.*#{TEMP_DIRECTORY}\//, "")
          file_path = File.join(ENV['RAILS_ASSET_ID'], file_path)
          file_ext = file.split(/\./)[-1].to_sym
          compressible = [:css, :js].include?(file_ext)

          options =  { :access => :public_read,
            :content_type => CONTENT_TYPES[file_ext] }.merge(MORNING_GLORY_CONFIG[Rails.env]['metadata'] || {})

          if (gzip && compressible)
            puts " ** Gzipping and uploading #{upload_bucket}/#{file_path}"

            buffer = StringIO.open('', 'w')
            gz = Zlib::GzipWriter.new(buffer)
            gz.write(open(file).read)
            gz.close
            content = buffer.string
            options['Content-Encoding'] = 'gzip'
          else
            puts " ** Uploading #{upload_bucket}/#{file_path}"
            content = open(file)
          end

          AWS::S3::S3Object.store(file_path, content, upload_bucket,
           options)
        end
      end

      # If the configured to delete the prev revision, and the prev revision value was in the YAML (not the blank concat of CLOUDFRONT_REVISION_PREFIX + revision number)
      if DELETE_PREV_REVISION && @@prev_cdn_revision != CLOUDFRONT_REVISION_PREFIX
        # TODO: Figure out how to delete from the S3 bucket properly
        puts "* Deleting previous CDN revision #{upload_bucket}/#{@@prev_cdn_revision}"
        AWS::S3::Bucket.find(upload_bucket).objects(:prefix => @@prev_cdn_revision).each do |object|
          puts " ** Deleting #{upload_bucket}/#{object.key}"
          object.delete
        end
      end

      if DELETE_OTHER_REVISIONS
        puts "* Deleting other CDN revisions in #{upload_bucket}"

        AWS::S3::Bucket.find(upload_bucket).each do |object|
          if object.key.start_with?(CLOUDFRONT_REVISION_PREFIX) && object.key.index(ENV['RAILS_ASSET_ID']).nil?
            puts " ** Deleting #{upload_bucket}/#{object.key}"
            object.delete
          end
        end
      end
    end

    desc "Bump the revision, compile any Sass stylesheets, and deploy assets to S3 and Cloudfront"
    task :deploy => [:environment] do |t, args|
      require 'aws/s3'
      require 'ftools'
      
      puts 'MorningGlory: Starting deployment to the Cloudfront CDN...'
      
      check_config
      
      update_revision

      compile_sass_if_available

      # Constants
      SYNC_DIRECTORY  = File.join(Rails.root, 'public')
      TEMP_DIRECTORY  = File.join(Rails.root, 'tmp', 'morning_glory', 'cloudfront', Rails.env, ENV['RAILS_ASSET_ID']);
      # Configuration constants
      BUCKET          = MORNING_GLORY_CONFIG[Rails.env]['bucket'] || Rails.env
      BUCKET_GZIP     = MORNING_GLORY_CONFIG[Rails.env]['bucket_gzip']
      DIRECTORIES     = MORNING_GLORY_CONFIG[Rails.env]['asset_directories'] || %w(images javascripts stylesheets)
      CONTENT_TYPES   = MORNING_GLORY_CONFIG[Rails.env]['content_types'] || {
                          :jpg => 'image/jpeg',
                          :png => 'image/png',
                          :gif => 'image/gif',
                          :css => 'text/css',
                          :js  => 'text/javascript'
                        }
      S3_LOGGING_ENABLED = MORNING_GLORY_CONFIG[Rails.env]['s3_logging_enabled'] || false
      DELETE_PREV_REVISION = MORNING_GLORY_CONFIG[Rails.env]['delete_prev_rev'] || false
      DELETE_OTHER_REVISIONS = MORNING_GLORY_CONFIG[Rails.env]['delete_other_revs'] || false
      REGEX_ROOT_RELATIVE_CSS_URL = /url\((\'|\")?(\/+.*(#{CONTENT_TYPES.keys.map { |k| '\.' + k.to_s }.join('|')}))\1?\)/
    
      # Copy all the assets into the temp directory for processing
      File.makedirs TEMP_DIRECTORY if !FileTest::directory?(TEMP_DIRECTORY)
      puts "* Copying files to working directory for cache-busting-renaming"
      DIRECTORIES.each do |directory|
        Dir[File.join(SYNC_DIRECTORY, directory, '**', "*.{#{CONTENT_TYPES.keys.join(',')}}")].each do |file|
          file_path = file.gsub(/.*public\//, "")
          temp_file_path = File.join(TEMP_DIRECTORY, file_path)

          File.makedirs(File.dirname(temp_file_path)) if !FileTest::directory?(File.dirname(temp_file_path))
        
          puts " ** Copied to #{temp_file_path}"
          FileUtils.copy file, temp_file_path
        end
      end

      puts "* Replacing image references within CSS files"
      DIRECTORIES.each do |directory|
        Dir[File.join(TEMP_DIRECTORY, directory, '**', "*.{css}")].each do |file|
          puts " ** Renaming image references within #{file}"
          buffer = File.new(file,'r').read.gsub(REGEX_ROOT_RELATIVE_CSS_URL) { |m| m.insert m.index('(') + ($1 ? 2 : 1), '/'+ENV['RAILS_ASSET_ID'] }
          File.open(file,'w') {|fw| fw.write(buffer)}
        end
      end

      # TODO: Update references within JS files
    
      AWS::S3::Base.establish_connection!(
        :access_key_id     => S3_CONFIG['access_key_id'],
        :secret_access_key => S3_CONFIG['secret_access_key']
      )

      begin
        upload_to_s3(BUCKET)
        upload_to_s3(BUCKET_GZIP, true) if BUCKET_GZIP
      rescue
        raise
      ensure
        puts "* Deleting temp cache files in #{TEMP_DIRECTORY}"
        FileUtils.rm_r TEMP_DIRECTORY
      end
      
      puts "MorningGlory: DONE! Your assets have been deployed to the Cloudfront CDN."
      
      if @@scm_commit_required == true
        puts '='*80
        puts "NB: You will need to commit the /config/morning_glory.yml file and update it on your servers."
        puts '='*80
      end
    end
  end
end