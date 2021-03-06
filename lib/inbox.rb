require 'json'
require 'rest-client'
require 'yajl'
require 'em-http'
require 'ostruct'

require 'account'
require 'api_account'
require 'api_thread'
require 'calendar'
require 'account'
require 'tag'
require 'message'
require 'draft'
require 'contact'
require 'file'
require 'calendar'
require 'event'
require 'folder'
require 'restful_model'
require 'restful_model_collection'
require 'version'


module Inbox

  class AccessDenied < StandardError; end
  class ResourceNotFound < StandardError; end
  class NoAuthToken < StandardError; end
  class UnexpectedAccountAction < StandardError; end
  class UnexpectedResponse < StandardError; end
  class APIError < StandardError
    attr_accessor :error_type
    def initialize(type, error)
      super(error)
      self.error_type = type
    end
  end
  class InvalidRequest < APIError; end
  class MessageRejected < APIError; end
  class SendingQuotaExceeded < APIError; end
  class ServiceUnavailable < APIError; end

  def self.interpret_http_status(result)
    # Handle HTTP errors and RestClient errors
    raise ResourceNotFound.new if result.code.to_i == 404
    raise AccessDenied.new if result.code.to_i == 403
  end

  def self.interpret_response(result, result_content, options = {})
    # Handle HTTP errors
    Inbox.interpret_http_status(result)

    # Handle content expectation errors
    raise UnexpectedResponse.new if options[:expected_class] && result_content.empty?
    json = options[:result_parsed]? result_content : JSON.parse(result_content)
    if json.is_a?(Hash) && (json['type'] == 'api_error' or json['type'] == 'invalid_request_error')
      if result.code.to_i == 400
        exc = InvalidRequest
      elsif result.code.to_i == 402
        exc = MessageRejected
      elsif result.code.to_i == 429
        exc = SendingQuotaExceeded
      elsif result.code.to_i == 503
        exc = ServiceUnavailable
      else
        exc = APIError
      end
      raise exc.new(json['type'], json['message'])
    end
    raise UnexpectedResponse.new(result.msg) if result.is_a?(Net::HTTPClientError)
    raise UnexpectedResponse.new if options[:expected_class] && !json.is_a?(options[:expected_class])
    json

  rescue JSON::ParserError => e
    # Handle parsing errors
    raise UnexpectedResponse.new(e.message)
  end


  class API
    attr_accessor :api_server
    attr_reader :access_token
    attr_reader :app_id
    attr_reader :app_secret

    def initialize(app_id, app_secret, access_token = nil, api_server = 'https://api.nylas.com',
                   service_domain = 'api.nylas.com')
      raise "When overriding the Inbox API server address, you must include https://" unless api_server.include?('://')
      @api_server = api_server
      @access_token = access_token
      @app_secret = app_secret
      @app_id = app_id
      @service_domain = service_domain
      @version = Inbox::VERSION

      if ::RestClient.before_execution_procs.empty?
        ::RestClient.add_before_execution_proc do |req, params|
          req.add_field('X-Inbox-API-Wrapper', 'ruby')
          req['User-Agent'] = "Nylas Ruby SDK #{@version} - #{RUBY_VERSION}"
        end
      end
    end

    def url_for_path(path)
      raise NoAuthToken.new if @access_token == nil and (@app_secret != nil or @app_id != nil)
      protocol, domain = @api_server.split('//')
      "#{protocol}//#{@access_token}:@#{domain}#{path}"
    end

    def url_for_authentication(redirect_uri, login_hint = '', options = {})
      trialString = 'false'
      if options[:trial] == true
        trialString = 'true'
      end
      "https://#{@service_domain}/oauth/authorize?client_id=#{@app_id}&trial=#{trialString}&response_type=code&scope=email&login_hint=#{login_hint}&redirect_uri=#{redirect_uri}"
    end

    def url_for_management
      protocol, domain = @api_server.split('//')
      accounts_path = "#{protocol}//#{@app_secret}:@#{domain}/a/#{@app_id}/accounts"
    end

    def set_access_token(token)
      @access_token = token
    end

    def token_for_code(code)
      data = {
          'client_id' => app_id,
          'client_secret' => app_secret,
          'grant_type' => 'authorization_code',
          'code' => code
      }

      ::RestClient.post("https://#{@service_domain}/oauth/token", data) do |response, request, result|
        json = Inbox.interpret_response(result, response, :expected_class => Object)
        return json['access_token']
      end
    end

    # API Methods
    def threads
      @threads ||= RestfulModelCollection.new(Thread, self)
    end

    def tags
      @tags ||= RestfulModelCollection.new(Tag, self)
    end

    def messages
      @messages ||= RestfulModelCollection.new(Message, self)
    end

    def files
      @files ||= RestfulModelCollection.new(File, self)
    end

    def drafts
      @drafts ||= RestfulModelCollection.new(Draft, self)
    end

    def contacts
      @contacts ||= RestfulModelCollection.new(Contact, self)
    end

    def calendars
      @calendars ||= RestfulModelCollection.new(Calendar, self)
    end

    def events
      @events ||= RestfulModelCollection.new(Event, self)
    end

    def folders
      @folders ||= RestfulModelCollection.new(Folder, self)
    end

    def labels
      @labels ||= RestfulModelCollection.new(Label, self)
    end

    def account
      path = self.url_for_path("/account")

      RestClient.get(path, {}) do |response,request,result|
        json = Inbox.interpret_response(result, response, {:expected_class => Object})
        model = APIAccount.new(self)
        model.inflate(json)
        model
      end
    end

    def using_hosted_api?
       return !@app_id.nil?
    end

    def accounts
          if self.using_hosted_api?
               @accounts ||= ManagementModelCollection.new(Account, self)
          else
               @accounts ||= RestfulModelCollection.new(APIAccount, self)
          end
    end

    def get_cursor(timestamp)
      # Get the cursor corresponding to a specific timestamp.
      warn "Nylas#get_cursor is deprecated. Use Nylas#latest_cursor instead."

      path = self.url_for_path("/delta/generate_cursor")
      data = { :start => timestamp }

      cursor = nil

      RestClient.post(path, data.to_json, :content_type => :json) do |response,request,result|
        json = Inbox.interpret_response(result, response, {:expected_class => Object})
        cursor = json["cursor"]
      end

      cursor
    end

    def latest_cursor
      # Get the cursor corresponding to a specific timestamp.
      path = self.url_for_path("/delta/latest_cursor")

      cursor = nil

      RestClient.post(path, :content_type => :json) do |response,request,result|
        json = Inbox.interpret_response(result, response, {:expected_class => Object})
        cursor = json["cursor"]
      end

      cursor
    end

    OBJECTS_TABLE = {
      "account" => Inbox::Account,
      "calendar" => Inbox::Calendar,
      "draft" => Inbox::Draft,
      "thread" => Inbox::Thread,
      "contact" => Inbox::Contact,
      "event" => Inbox::Event,
      "file" => Inbox::File,
      "message" => Inbox::Message,
      "tag" => Inbox::Tag,
      "folder" => Inbox::Folder,
      "label" => Inbox::Label,
    }

    def _build_exclude_types(exclude_types)
      exclude_string = "&exclude_types="

      exclude_types.each do |value|
        count = 0
        if OBJECTS_TABLE.has_value?(value)
          param_name = OBJECTS_TABLE.key(value)
          exclude_string += "#{param_name},"
        end
      end

      exclude_string = exclude_string[0..-2]
    end

    def deltas(cursor, exclude_types=[])
      raise 'Please provide a block for receiving the delta objects' if !block_given?
      exclude_string = ""

      if exclude_types.any?
        exclude_string = _build_exclude_types(exclude_types)
      end

      # loop and yield deltas until we've come to the end.
      loop do
        path = self.url_for_path("/delta?cursor=#{cursor}#{exclude_string}")
        json = nil

        RestClient.get(path) do |response,request,result|
          json = Inbox.interpret_response(result, response, {:expected_class => Object})
        end

        start_cursor = json["cursor_start"]
        end_cursor = json["cursor_end"]

        json["deltas"].each do |delta|
          if not OBJECTS_TABLE.has_key?(delta['object'])
            next
          end

          cls = OBJECTS_TABLE[delta['object']]
          obj = cls.new(self)

          case delta["event"]
          when 'create', 'modify'
              obj.inflate(delta['attributes'])
              obj.cursor = delta["cursor"]
              yield delta["event"], obj
          when 'delete'
              obj.id = delta["id"]
              obj.cursor = delta["cursor"]
              yield delta["event"], obj
          end
        end

        break if start_cursor == end_cursor
        cursor = end_cursor
      end
    end

    def delta_stream(cursor, exclude_types=[], timeout=0)
      raise 'Please provide a block for receiving the delta objects' if !block_given?

      exclude_string = ""

      if exclude_types.any?
        exclude_string = _build_exclude_types(exclude_types)
      end

      # loop and yield deltas indefinitely.
      path = self.url_for_path("/delta/streaming?cursor=#{cursor}#{exclude_string}")

      parser = Yajl::Parser.new(:symbolize_keys => false)
      parser.on_parse_complete = proc do |data|
        delta = Inbox.interpret_response(OpenStruct.new(:code => '200'), data, {:expected_class => Object, :result_parsed => true})

        if not OBJECTS_TABLE.has_key?(delta['object'])
          next
        end

        cls = OBJECTS_TABLE[delta['object']]
        obj = cls.new(self)

        case delta["event"]
          when 'create', 'modify'
            obj.inflate(delta['attributes'])
            obj.cursor = delta["cursor"]
            yield delta["event"], obj
          when 'delete'
            obj.id = delta["id"]
            obj.cursor = delta["cursor"]
            yield delta["event"], obj
        end
      end

      EventMachine.run do
        http = EventMachine::HttpRequest.new(path, :connect_timeout => 0, :inactivity_timeout => timeout).get(:keepalive => true)
        http.stream do |chunk|
          parser << chunk
        end
        http.errback do
          raise UnexpectedResponse.new http.error
        end
      end
    end
  end
end

Nylas = Inbox.clone
