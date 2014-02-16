# encoding: UTF-8
require "rest_client"
require "nokogiri"
require "dotenv"
require "listen"

require "time"
require "json"
require "open-uri"
require "optparse"

Dotenv.load

module Selfcaster
  URL = ENV["SELFCAST_URL"]
  AUTH_TOKEN = ENV["SELFCAST_TOKEN"]

  CHANNELS = {
    "NHK-FM" => 1
  }
  # 0:Sun, 1:Mon, 2:Tue, 3:Wed, 4:Thu, 5:Fri, 6:Sat
  PROGRAMS = {
    "NHK-FM" => [
      {name: "オペラ・ファンタスティカ", at: "1400", weekdays: [5]},
      {name: "DJ クラシック", at: "2110", weekdays: [5]},
      {name: "現代の音楽", at: "0600", weekdays: [6]},
      {name: "クラシックの迷宮", at: "2100", weekdays: [6]},
      {name: "きらクラ!", at: "1400", weekdays: [0]},
      {name: "ビバ! 合唱", at: "0720", weekdays: [0]},
      {name: "吹奏楽のひびき", at: "0810", weekdays: [0]},
      {name: "名演奏ライブラリー", at: "0900", weekdays: [0]},
      {name: "ブラボー! オーケストラ", at: "1920", weekdays: [0]},
      {name: "リサイタル・ノヴァ", at: "2020", weekdays: [0]},
      {name: "ベストオブクラシック", at: "1930", weekdays: [1, 2, 3, 4, 5]},
      {name: "古楽の楽しみ", at: "0600", weekdays: [1, 2, 3, 4, 5]},
      {name: "クラシックカフェ", at: "1400", weekdays: [1, 2, 3, 4]},
      {name: "名曲の小箱", at: "0550", weekdays: [0, 1, 2, 3, 4, 5, 6]},
      {name: "名曲の小箱", at: "2255", weekdays: [6]},
      {name: "名曲スケッチ", at: "0050", weekdays: [2, 3, 4, 5, 6]},
      {name: "ガットのしらべ", at: "2015", weekdays: [6]}
    ]
  }
  class Runner
    def self.run(argv)
      new.run(argv)
    end

    def options
      @options ||= {
        delete: false,
        update_metadata: false,
        watch: false
      }
    end

    def run(argv)
      optparse = OptionParser.new do |o|
        o.on("-d", "--[no-]delete"){|b| options[:delete] = b }
        o.on("-m", "--[no-]update-metadata"){|b| options[:update_metadata] = b }
        o.on("-w", "--watch"){|b| options[:watch] = b }
        o.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options] file_or_directory[...]"
      end
      optparse.parse!(argv)

      if argv.empty? && !options[:update_metadata]
        STDERR.print(optparse.help)
        exit 1
      end

      if options[:watch]
        watch(argv)
      else
        scan(argv)
        update_metadata if options[:update_metadata]
      end
    end

    def watch(paths)
      listener = Listen.to(*paths) do
        scan(paths)
        update_metadata if options[:update_metadata]
      end
      listener.start
      trap(:INT){
        STDERR.puts "Exiting"
        listener.stop
        exit 1
      }
      STDERR.puts "Listen #{paths.join(", ")}"
      sleep
    end

    def scan(paths)
      files = paths.map{|file_or_directory|
        if File.directory?(file_or_directory)
          Dir.glob(File.join(file_or_directory, "**/*")).to_a
        else
          file_or_directory
        end
      }.flatten

      files.each{|file| upload(file) }
    end

    def upload(file)
      pattern = /(\d\d\d\d)(\d\d)(\d\d)(\d\d)(\d\d)\d\d-FM\.mp3/
      return unless pattern =~ File.basename(file)
      puts "Uploading... #{file}"

      year, month, day, hour, min, channel = $~.captures
      time = Time.new(year.to_i, month.to_i, day.to_i, hour.to_i, min.to_i)

      channel = "NHK-FM"

      attributes = {
        content_filename: File.basename(file),
        title: build_name(channel, time),
        published_at: time.iso8601
      }

      puts "Title: #{attributes[:title]}"
      puts "Published at: #{attributes[:published_at]}"

      response = RestClient.post(build_url(channel), item: attributes, auth_token: AUTH_TOKEN)
      puts "Metadata created on #{response.headers[:location]}"

      presigned_post = JSON.parse(response)["presigned_post"]
      response = RestClient.post(presigned_post["url"], presigned_post["fields"].merge(file: File.new(file)))

      puts "Uploaded on #{response.headers[:location]}"
      puts ""

      File.delete(file) if options[:delete]
    end

    def build_url(channel)
      "#{URL}/channels/#{CHANNELS[channel]}/items.json"
    end

    def build_name(channel, time)
      at = time.strftime("%H%M")
      program = PROGRAMS[channel].find{|program|
        program[:at] == at && program[:weekdays].include?(time.wday)
      }
      if program
        program[:name] + " #{time.year}年#{time.month}月#{time.day}日"
      else
        "#{time.year}年#{time.month}月#{time.day}日 #{time.strftime("%H:%M")}"
      end
    end

    def update_metadata
      update_metadata_for_program("NHK-FM", "クラシックカフェ", get_metadata_from_nhk("http://www4.nhk.or.jp/c-cafe/5/"))
      update_metadata_for_program("NHK-FM", "ベストオブクラシック", get_metadata_from_nhk("http://www4.nhk.or.jp/bescla/5/"))
      update_metadata_for_program("NHK-FM", "古楽の楽しみ", get_metadata_from_nhk("http://www4.nhk.or.jp/kogaku/5/"))
      update_metadata_for_program("NHK-FM", "名演奏ライブラリー", get_metadata_from_nhk("http://www4.nhk.or.jp/meiensou/5/"))
      update_metadata_for_program("NHK-FM", "きらクラ!", get_metadata_from_nhk("http://www4.nhk.or.jp/kira/5/"))
      update_metadata_for_program("NHK-FM", "ブラボー! オーケストラ", get_metadata_from_nhk("http://www4.nhk.or.jp/bravo/5/"))
      update_metadata_for_program("NHK-FM", "DJ クラシック", get_metadata_from_nhk("http://www4.nhk.or.jp/dj-classic/5/"))
      update_metadata_for_program("NHK-FM", "リサイタル・ノヴァ", get_metadata_from_nhk("http://www4.nhk.or.jp/nova/5/"))
    end

    def update_metadata_for_program(channel_name, program_name, metadata)
      puts "Checking metadata #{channel_name} #{program_name}"
      JSON.parse(RestClient.get(build_url(channel_name), params: {title: program_name, auth_token: AUTH_TOKEN})).each do |item|
        date = Time.parse(item["published_at"]).getlocal.to_date
        if (metadata_for_item = metadata.find{|m| m[:date] == date }) &&
           item["description"] != metadata_for_item[:description]
          puts "Updating metadata for #{item["title"]}..."
          update_metadata_for_item(item["channel_id"], item["id"], description: metadata_for_item[:description])
        end
      end
    end

    def update_metadata_for_item(channel_id, item_id, metadata)
      url = "#{URL}/channels/#{channel_id}/items/#{item_id}.json"
      RestClient.put(url, item: metadata, auth_token: AUTH_TOKEN)
    end

    def get_metadata_from_nhk(url)
      doc = Nokogiri::HTML.parse(RestClient.get(url))
      doc.css("section.section_onair").map do |section|
        date = Date.parse section.css(".date time")[0]["datetime"]
        description = section.css(".summary_text p").inner_html.gsub(/<br>/, "\n")
        {date: date, description: description}
      end
    end
  end
end
