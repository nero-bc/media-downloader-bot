require 'bundler/setup'
require 'active_support/all'
require 'dotenv'
require 'telegram/bot'

require 'tmpdir'
require 'shellwords'
require 'open3'
require 'rack/mime'

require_relative 'exts/sym_mash'
require_relative 'bot/helpers'
require_relative 'bot/zipper'

class Bot

  attr_reader :bot

  include Helpers
  include Zipper

  def initialize token
    @token = token
    @dir   = Dir.mktmpdir 'media-downloader-'
  end

  def start
    Telegram::Bot::Client.run @token, logger: Logger.new(STDOUT) do |bot|
      @bot = bot

      puts 'bot: started, listening'
      @bot.listen do |msg|
        Thread.new do
          next unless msg.is_a? Telegram::Bot::Types::Message
          react msg
        end
        Thread.new{ sleep 1 and abort } if @exit # wait for other msg processing and trigger systemd restart
      end
    end
  end

  def react msg
    args = msg.text.split(/\s+/)
    url  = args.shift
    download msg, url, *args
  rescue => e
    report_error msg, e
  end

  CMD = "youtube-dl -4 --user-agent 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36' -f worst --write-info-json '%{url}'"

  # missing mimes
  Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'

  def download msg, url, *args
    args = args.each.with_object(SymMash.new){ |a, h| h[a] = 1 }
    resp = send_message msg, "Downloading..."

    Dir.mktmpdir "media-downloader-#{url.parameterize}" do |d|
      _o, e, s = Open3.capture3 CMD % {url: url}, chdir: d
      if s != 0
        edit_message msg, resp.result.message_id, text: "Download failed:\n<pre>#{he e}</pre>", parse_mode: 'HTML'
        resp = nil
        break
      end

      Dir.glob "#{d}/*.info.json" do |f|
        info   = SymMash.new JSON.parse File.read f

        fnbase = File.basename info._filename, File.extname(info._filename)
        fn_in  = Dir.glob("#{d}/#{fnbase}*").first
        mtype  = Rack::Mime.mime_type File.extname fn_in
        type   = if mtype.index 'video' then Types.video elsif mtype.index 'audio' then Types.audio end
        raise "Unknown type for #{info._filename}" unless type
        fn_out = "#{d}/#{fnbase}.#{type.ext}"

        edit_message msg, resp.result.message_id, text: (resp.text += "\nConverting...")
        send "zip_#{type.name}", fn_in, fn_out

        unless args.nocaption
          text  = "_#{e info.title}_"
          text += "\nby #{e info.uploader}" if info.uploader
          text += "\n\n#{url}"
        end

        edit_message msg, resp.result.message_id, text: (resp.text += "\nSending...")
        fn_io = Faraday::UploadIO.new fn_out, mtype
        send_message msg, text, type: type.name, type.name => fn_io
      end
    end
  ensure
    delete_message msg, resp.result.message_id, wait: nil if resp
  end

end
