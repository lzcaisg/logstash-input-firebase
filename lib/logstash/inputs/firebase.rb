# encoding: utf-8
require 'logstash/inputs/base'
require 'logstash/namespace'
require 'socket' # for Socket.gethostname
require 'rufus/scheduler'
require 'rest-firebase'

# Retrieves data from the Firebase real-time database https://firebase.google.com/docs/database/rest/retrieve-data[via the REST API].
# This input plugin can work in two modes:
# 1. Retrieve the value of database references on a fixed schedule (at midnight, every 5 minutes, etc)
# 2. Retrieve the value of database references as it changes (via the https://firebase.google.com/docs/database/rest/retrieve-data#section-rest-streaming[streaming REST API])
#
# ==== Example
# For retrieving database values on a fixed time interval, the config should look like below.
# In order to use the streaming API and receive changes as they occur, simply remove the `schedule`
# setting altogether and this input will get notified on every change in the value of the tracked database references.
#
# [source,ruby]
# ----------------------------------
input {
  firebase {
    url => 'https://spirit-iot-test.firebaseio.com'
    auth => 'AIzaSyBASV09Np3FFgymUFJcXV6czKsbCCYautM'
    # Supports 'cron', 'every', 'at' and 'in' schedules by rufus scheduler
    # schedule => { cron => '* * * * * UTC'}
    refs => {
      sensor_data => {
        path => '/sensor'
      }
      # company_orders => {
      #   path => '/company/orders'
      #   orderBy => '$key'
      #   limitToFirst => 3
      # }
    }
  }
}

output {
  stdout {
    codec => rubydebug
  }
}
# ----------------------------------

class LogStash::Inputs::Firebase < LogStash::Inputs::Base
  config_name 'firebase'

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, 'plain'

  # The Firebase URL endpoint
  config :url, :validate => :string, :required => true

  # The secret to use for authenticating
  config :secret, :validate => :string, :required => false

  # A Hash of database references to retrieve
  config :refs, :validate => :hash, :required => true

  # The target field for placing the received data. If this setting is omitted, the data will be stored at the root (top level) of the event.
  config :target, :validate => :string, :required => false

  # The number of seconds to wait before the connection times out (default: 10s)
  config :firebase_timeout, :validate => :number, :default => 10

  # The number of retries to attempt in case of failures (default: 3)
  config :firebase_retries, :validate => :number, :default => 3

  # The amount of time to wait before refreshing the authentication token, if any (default: 82800s = 23h)
  # Set to -1 to disable the auto-refresh of the authentication token
  config :firebase_auth_ttl, :validate => :number, :default => 82800

  # The set of streaming events to listen to (possible values are `put`, `patch`, `keep-alive`, `cancel`, `auth_revoked)
  # (https://firebase.google.com/docs/database/rest/retrieve-data#section-rest-streaming[see events])
  config :events, :validate => :array, :required => false, :default => ['put', 'patch']

  # Schedule of when to periodically poll from the urls
  # Format: A hash with
  #   + key: 'cron' | 'every' | 'in' | 'at'
  #   + value: string
  # Examples:
  #   a) { 'every' => '1h' }
  #   b) { 'cron' => '* * * * * UTC' }
  # See: rufus/scheduler for details about different schedule options and value string format
  config :schedule, :validate => :hash, :required => false

  # If you'd like to work with the request/response metadata.
  # Set this value to the name of the field you'd like to store a nested
  # hash of metadata.
  config :metadata_target, :validate => :string, :default => LogStash::Event::METADATA

  public
  Schedule_types = %w(cron every at in)
  def register
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)

    @logger.info('Registering firebase input', :url => @url, :schedule => @schedule)

    setup_firebase_client!
    setup_queries!
  end # def register

  private
  def setup_firebase_client!
    @logger.info('Setting up firebase client')

    RestFirebase.pool_size = -1
    @firebase = RestFirebase.new :site => @url,
       :secret => @secret,
       :d => {:auth_data => 'logstash'},
       :log_method => method(:log),
       # `error_callback` would get called each time there's
       # an exception. Useful for monitoring and logging.
       :error_callback => method(:error),
       # `timeout` in seconds
       :timeout => @firebase_timeout,
       # `max_retries` upon failures. Default is: `0`
       :max_retries => @firebase_retries,
       # `retry_exceptions` for which exceptions should retry
       # Default is: `[IOError, SystemCallError]`
       :retry_exceptions => [IOError, SystemCallError, Timeout::Error],
       # `auth_ttl` describes when we should refresh the auth
       # token. Set it to `false` to disable auto-refreshing.
       # The default is 23 hours.
       :auth_ttl => @firebase_auth_ttl > -1 ? @firebase_auth_ttl : false,
       # `auth` is the auth token from Firebase. Leave it alone
       # to auto-generate. Set it to `false` to disable it.
       :auth => false # Ignore auth for this example!

    @reconnect = true
    @streams = Array.new
  end # def setup_firebase_client!

  private
  def log(msg)
    @logger.info(msg)
  end

  private
  def error(err)
    @logger.error(err)
  end

  private
  def setup_queries!
    @queries = Hash[@refs.map {|name, raw_spec| [name, setup_query(raw_spec)] }]
  end # def setup_queries!

  private
  def setup_query(raw_spec)
    if raw_spec.is_a?(Hash)
      spec = Hash[raw_spec.clone.map {|k,v| [k.to_sym, v] }] # symbolize keys
    else
      raise LogStash::ConfigurationError, 'Invalid query spec: '#{raw_spec}', expected a Hash!'
    end

    spec
  end # def setup_query

  public
  def run(queue)
    if @schedule
      setup_schedule(queue)
    else
      setup_streaming(queue)
    end
  end # def run

  private
  def setup_schedule(queue)
    @logger.info('Setting up schedule', :schedule => @schedule)

    #schedule hash must contain exactly one of the allowed keys
    msg_invalid_schedule = 'Invalid config. schedule hash must contain ' +
        'exactly one of the following keys - cron, at, every or in'
    raise Logstash::ConfigurationError, msg_invalid_schedule if @schedule.keys.length !=1
    schedule_type = @schedule.keys.first
    schedule_value = @schedule[schedule_type]
    raise LogStash::ConfigurationError, msg_invalid_schedule unless Schedule_types.include?(schedule_type)

    @scheduler = Rufus::Scheduler.new(:max_work_threads => 1)
    #as of v3.0.9, :first_in => :now doesn't work. Use the following workaround instead
    opts = schedule_type == 'every' ? { :first_in => 0.01 } : {}
    @scheduler.send(schedule_type, schedule_value, opts) { run_once(queue) }
    @scheduler.join
  end # def setup_schedule

  private
  def setup_streaming(queue)
    @queries.each do |name, query|
      stream_firebase(queue, name, query)
    end
  end # def setup_streaming

  private
  def run_once(queue)
    @queries.each do |name, query|
      query_firebase(queue, name, query)
    end
  end # def run_once

  private
  def query_firebase(queue, name, query)
    @logger.debug('Querying Firebase', :url => @url, :name => name, :query => query) if @logger.debug?
    started = Time.now

    @firebase.get(query[:path]) do |data|
      if data.kind_of?(Exception)
        @logger.error('Error while querying Firebase', :error => data)
        handle_failure(queue, name, query, data, Time.now - started)
      else
        handle_success(queue, name, query, 'get', data, Time.now - started)
      end
    end

  end # def query_firebase

  private
  def stream_firebase(queue, name, query)
    @logger.info('Setting up streaming', :path => query[:path])

    es = @firebase.event_source(query[:path])
    es.onopen   { |sock| }
    es.onreconnect{ |error, sock|
      @logger.error('Firebase connection dropped', :reconnect => @reconnect, :error => error)
      @reconnect
    }
    es.onmessage{ |event, data, sock|
      # only consider some specific events
      return unless @events.include? event

      handle_success(queue, name, query, event, data, 0)
    }
    es.onerror  { |error, sock|
      handle_failure(queue, name, query, error, 0)
    }
    es.start
    @streams << es
  end # def stream_firebase

  private
  def handle_success(queue, name, query, fbevent, data, execution_time)
    data, query = normalize_data(data, query)
    event = @target ? LogStash::Event.new(@target => data) : LogStash::Event.new(data)
    apply_metadata(event, name, query, fbevent, data, execution_time)
    decorate(event) # adds @version, @timestamp and tags
    queue << event
  end # def handle_success

  private
  def normalize_data(data, query)
    data, query = normalize_stream_data(data, query) unless @schedule
    data, query = normalize_get_data(data, query)
    return data, query
  end # def normalize_data

  # When streaming data, the returned data is always a hash containing :path and :data. Append the :path to
  # the query path and return the data separately
  private
  def normalize_stream_data(data, query)
    copy = Hash[query.map {|k,v| [k, v.clone] }]
    unless data['path'] == '/'
      copy[:path] << data['path']
    end
    return data['data'], copy
  end # def normalize_stream_data

  # When performing a get, the returned data can either be a hash or a primitive value (in case the ref is a leaf).
  # In the latter case, make sure to put the retrieved value in a field named after the leaf path.
  private
  def normalize_get_data(data, query)
    unless data.is_a?(Hash)
      field = query[:path].split('/')[-1]
      data = {field => data}
    end
    return data, query
  end # def normalize_get_data

  private
  def handle_failure(queue, name, query, exception, execution_time)
    event = LogStash::Event.new
    apply_metadata(event, name, query, 'error', exception, execution_time)

    event.tag('_firebase_failure')

    # This is also in the metadata, but we send it anyone because we want this
    # persisted by default, whereas metadata isn't. People don't like mysterious errors
    event.set('firebase_failure', {
        'query' => structure_query(query),
        'query_name' => name,
        'error' => exception.to_s,
        'backtrace' => exception.backtrace,
        'runtime_seconds' => execution_time
    })

    queue << event
  rescue StandardError, java.lang.Exception => e
    @logger.error? && @logger.error('Cannot send Firebase query or send the error as an event!',
                                    :exception => e,
                                    :exception_message => e.message,
                                    :exception_backtrace => e.backtrace,
                                    :url => @url,
                                    :name => name,
                                    :query => query
    )
  end # def handle_failure

  private
  def apply_metadata(event, name, query, fbevent, data=nil, execution_time=0)
    return unless @metadata_target
    event.set(@metadata_target, event_metadata(name, query, fbevent, data, execution_time))
  end # def apply_metadata

  private
  def event_metadata(name, query, fbevent, data=nil, execution_time=0)
    meta = {
        'host' => @host,
        'event' => fbevent,
        'query_name' => name,
        'query_spec' => structure_query(query),
        'runtime_seconds' => execution_time
    }
    meta
  end # def event_metadata

  private
  # Turn query into a hash for friendlier logging / ES indexing
  def structure_query(query)
    # stringify any keys to normalize
    Hash[query.map {|k,v| [k.to_s,v] }]
  end

  public
  def stop
    @scheduler.stop if @scheduler
    @reconnect = false
    @streams.each { |s| s.close }
    @streams.clear
    @firebase.auth = nil
    RestFirebase.shutdown
  end
end # class LogStash::Inputs::Firebase
