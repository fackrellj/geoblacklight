# frozen_string_literal: true

desc 'Run test suite'
task :ci do
  shared_solr_opts = { managed: true, verbose: true, persist: false, download_dir: 'tmp' }
  shared_solr_opts[:version] = ENV['SOLR_VERSION'] if ENV['SOLR_VERSION']

  success = true
  SolrWrapper.wrap(shared_solr_opts.merge(port: 8985, instance_dir: 'tmp/blacklight-core')) do |solr|
    solr.with_collection(name: "blacklight-core", dir: Rails.root.join("solr", "conf").to_s) do
      system 'RAILS_ENV=test bundle exec rake geoblacklight:index:seed'
      system 'RAILS_ENV=test TESTOPTS="-v" bundle exec rails test:system test' || success = false
    end
  end

  exit!(1) unless success
end

namespace :jhu do
  desc 'Run Solr and GeoBlacklight for interactive development'
  task :server, [:rails_server_args] do
    require 'solr_wrapper'

    shared_solr_opts = { managed: true, verbose: true, persist: false, download_dir: 'tmp' }
    shared_solr_opts[:version] = ENV['SOLR_VERSION'] if ENV['SOLR_VERSION']

    SolrWrapper.wrap(shared_solr_opts.merge(port: 8983, instance_dir: 'tmp/blacklight-core')) do |solr|
      solr.with_collection(name: "blacklight-core", dir: Rails.root.join("solr", "conf").to_s) do
        puts "Solr running at http://localhost:8983/solr/blacklight-core/, ^C to exit"
        puts ' '
        begin
          Rake::Task['geoblacklight:solr:seed'].invoke
          system "bundle exec rails s -b 0.0.0.0"
          sleep
        rescue Interrupt
          puts "\nShutting down..."
        end
      end
    end
  end

  desc "Start solr server for testing."
  task :test do
    if Rails.env.test?
      shared_solr_opts = { managed: true, verbose: true, persist: false, download_dir: 'tmp' }
      shared_solr_opts[:version] = ENV['SOLR_VERSION'] if ENV['SOLR_VERSION']

      SolrWrapper.wrap(shared_solr_opts.merge(port: 8985, instance_dir: 'tmp/blacklight-core')) do |solr|
        solr.with_collection(name: "blacklight-core", dir: Rails.root.join("solr", "conf").to_s) do
          puts "Solr running at http://localhost:8985/solr/#/blacklight-core/, ^C to exit"
          begin
            Rake::Task['geoblacklight:solr:seed'].invoke
            sleep
          rescue Interrupt
            puts "\nShutting down..."
          end
        end
      end
    else
      system('rake jhu:test RAILS_ENV=test')
    end
  end

  desc "Start solr server for development."
  task :development do
    shared_solr_opts = { managed: true, verbose: true, persist: false, download_dir: 'tmp' }
    shared_solr_opts[:version] = ENV['SOLR_VERSION'] if ENV['SOLR_VERSION']

    SolrWrapper.wrap(shared_solr_opts.merge(port: 8983, instance_dir: 'tmp/blacklight-core')) do |solr|
      solr.with_collection(name: "blacklight-core", dir: Rails.root.join("solr", "conf").to_s) do
        puts "Solr running at http://localhost:8983/solr/#/blacklight-core/, ^C to exit"
        begin
          Rake::Task['geoblacklight:solr:seed'].invoke
          sleep
        rescue Interrupt
          puts "\nShutting down..."
        end
      end
    end
  end

  desc "Download the B1G Geoportal data.json file."
  task :b1g_download_data do
    require 'down'
    begin
      Down.download("https://geo.btaa.org/data.json", destination: "#{Rails.root}/tmp/b1g_data.json")

      puts "Success - B1G Geoportal data downloaded to tmp/b1g_data.json"
    rescue
      puts "Error - could not download B1G Geoportal data!"
    end
  end

  desc "Download the UMD B1G Geoportal data."
  task :b1g_umd_data => [:b1g_download_data] do
    begin
      # Loop it
      cleaned_data = Array.new
      data = JSON.parse(IO.read('tmp/b1g_data.json'))
      data.each do |doc|
        if doc["dct_provenance_s"] == "Maryland"
          cleaned = doc.except!(
            "_version_",
            "timestamp",
            "solr_bboxtype",
            "solr_bboxtype__minX",
            "solr_bboxtype__minY",
            "solr_bboxtype__maxX",
            "solr_bboxtype__maxY"
          )

          cleaned_data << cleaned
        end
      end

      IO.write('tmp/b1g_umd.json', cleaned_data.to_json)

      puts "Success - B1G UMD data extracted to tmp/b1g_umd.json"
    rescue
      puts "Error - could not process UMD data!"
    end
  end

  desc "Index the UMD B1G Geoportal data."
  task :b1g_index_umd_data => [:b1g_umd_data] do
    require 'net/http'
    require 'uri'

    uri = URI.parse("http://localhost:8983/solr/blacklight-core/update/json?commit=true")
    request = Net::HTTP::Post.new(uri)
    request.content_type = "application/json"
    request.body = File.read("#{Rails.root}/tmp/b1g_umd.json")

    req_options = {
      use_ssl: uri.scheme == "https",
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end

    puts response.code
  end

  desc "Put sample JHU data into solr"
  task :index_jhu_fixtures => :environment do
    docs = Dir['spec/fixtures/solr_documents/jhu_documents/*.json'].map { |f| JSON.parse File.read(f) }.flatten
    Blacklight.default_index.connection.add docs
    Blacklight.default_index.connection.commit
  end
end
