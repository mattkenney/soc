require 'haml'
require 'omniauth-twitter'
require 'rack/session/redis'
require 'redis'
require 'sinatra'
require 'twitter'

configure do
  # we'll use redis sessions instead of cookie sessions
  disable :sessions
  use Rack::Session::Redis, {
    :expire_after => ENV.fetch('SESSION_TIMEOUT', '43200').to_i
  }

  # log in with Twitter
  use OmniAuth::Builder do
    provider :twitter, ENV['CONSUMER_KEY'], ENV['CONSUMER_SECRET']
  end

  set :haml, :escape_html => true
end

helpers do
  def twitter()
    credentials = session[:twitter_credentials]
    Twitter::REST::Client.new do |config|
      config.consumer_key        = ENV['CONSUMER_KEY']
      config.consumer_secret     = ENV['CONSUMER_SECRET']
      config.access_token        = credentials.token
      config.access_token_secret = credentials.secret
    end
  end

  def format_time(time_string)
    dt = DateTime.parse(time_string)
    offset = session[:utc_offset]
    if offset.nil?
      offset = 0
    end
    zone = "%+03d:%02d" % [ offset / 3600, offset % 3600]
    t = dt.to_time.localtime(zone)
    s = t.strftime('%FT%T')
    dt = DateTime.parse(s)
    dt.strftime('%l:%M:%S %p %-m/%-d/%Y')
  end

  def format_context(status)
    {
      :name => status[:user][:name],
      :screen_name => status[:user][:screen_name],
      :created_at => format_time(status[:created_at]),
      :profile => "https://twitter.com/%s" %
        [ status[:user][:screen_name] ],
      :url => "https://twitter.com/%s/status/%s" %
        [ status[:user][:screen_name], status[:id_str] ],
    }
  end

  def format_status(status, message = '')
    contexts = []
    ctx = format_context(status)
    while true
      contexts << ctx
      retweet = status[:retweeted_status]
      break if not retweet
      status = retweet
      ctx = format_context(status)
      ctx[:is_retweet] = true
    end
    in_reply_to = false
    if status[:in_reply_to_screen_name] and status[:in_reply_to_status_id_str]
      in_reply_to = "https://twitter.com/%s/status/%s" %
        [status[:in_reply_to_screen_name], status[:in_reply_to_status_id_str]]
    end
    result = {
      :contexts => contexts,
      :content_html => format_content_html(status),
      :message => message,
      :in_reply_to => in_reply_to
    }
  end

  def format_content_html(status)
    result = status[:text]
    if status[:entities][:urls]
      status[:entities][:urls].each do |url|
        href = CGI::escapeHTML(url[:expanded_url])
        if /^https:\/\/twitter\.com\/[^\/]+\/status\/[0-9]+$/ =~ url[:expanded_url]
        then
          result.gsub! url[:url], "<input name=\"t\" type=\"submit\" value=\"#{href}\" />"
        else
          result.gsub! url[:url], "<a href=\"#{href}\">#{href}</a>"
        end
      end
    end
    if status[:entities][:media]
      status[:entities][:media].each do |url|
        href = CGI::escapeHTML(url[:media_url_https])
        result.gsub! url[:url], "<a href=\"#{href}\">[#{href}]</a>"
      end
    end
    result.gsub "\n", "<br />"
  end

  def get_status(delta = 0)
    redis = Redis.new
    status_key = 'soc:uid:' + session[:uid] + ':statuses'
    count = redis.llen status_key
    index_key = 'soc:uid:' + session[:uid] + ':status_index'
    index = (redis.get index_key).to_i
    if delta == Float::INFINITY
      index = (index < count - 1) ? (count - 1) : count
    elsif delta == -Float::INFINITY
      index = (index > 0) ?  0 : -1
    else
      index += delta
    end
    if index < 0
      string = redis.lindex(status_key, 0)
      if string.nil?
        new = twitter().home_timeline :count => 200
      else
        top = Marshal.load string
        # include refetch newest cached tweet to see if we missed any
        since = top.id - 1
        new = twitter().home_timeline :count => 200, :since_id => since
        if top.id != new[-1].id
          # LATER: 
        end
      end
      if !new.nil? and new.length > 0
        redis.del status_key
        strings = new.map { |item| Marshal.dump item }
        count = redis.rpush status_key, strings
        index += (count - 1)
      end
    elsif index >= count
      string = redis.lindex(status_key, -1)
      if string.nil?
        new = twitter().home_timeline :count => 200
      else
        bottom = Marshal.load string
        max = bottom.id
        new = twitter().home_timeline :count => 200, :max_id => max
      end
      if !new.nil? and new.length > 0
        strings = new.map { |item| Marshal.dump item }
        count = redis.rpush(status_key, strings)
      end
    end
    index = [0, [index, count].min].max
    redis.set index_key, index
    status = Marshal.load redis.lindex(status_key, index)
    format_status status.attrs, index
  end
end

before do
  pass if request.path_info =~ /^\/auth\//
  redirect to('/auth/twitter') if session[:uid].nil?
end

get '/auth/failure' do
  'Login system failure'
end

get '/auth/twitter/callback' do
  session[:uid] = env['omniauth.auth']['uid']
  session[:utc_offset] = env['omniauth.auth'][:extra][:raw_info][:utc_offset]
  session[:twitter_credentials] = env['omniauth.auth']['credentials']
  redirect to('/')
end

get '/' do
  haml :root, :locals => get_status
end

post '/' do
  delta = 0
  if !params[:p].nil?
    delta = 1
  elsif !params[:n].nil?
    delta = -1
  elsif !params[:b].nil?
    delta = 20
  elsif !params[:f].nil?
    delta = -20
  elsif !params[:s].nil?
    delta = Float::INFINITY
  elsif !params[:e].nil?
    delta = -Float::INFINITY
  elsif !params[:t].nil?
    status = twitter().status(params[:t])
    return haml :root, :locals => format_status(status.attrs)
  end
  haml :root, :locals => get_status(delta)
end
