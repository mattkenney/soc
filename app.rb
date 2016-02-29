#
# Copyright 2016 Matt Kenney
#
# This file is part of Soc.
#
# Soc is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# Fotocog is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Soc.  If not, see <http://www.gnu.org/licenses/>.
#
require 'haml'
require 'omniauth-twitter'
require 'pocket-ruby'
require 'rack/session/redis'
require 'redis'
require 'sinatra'
require 'twitter'
require 'yaml'

configure :production do
  # do not log requests to stderr, rely on nginx request log
  set :logging, false
end

configure do
  set :haml, :escape_html => true

  set :config, YAML::load_file(File.join(__dir__, 'config.yaml'))

  # we'll use redis sessions instead of cookie sessions
  disable :sessions
  use Rack::Session::Redis, {
    :expire_after => settings.config['session_timeout'].to_i
  }

  # log in with Twitter
  use OmniAuth::Builder do
    provider :twitter, settings.config['twitter']['consumer_key'],
        settings.config['twitter']['consumer_secret']
  end
end

Pocket.configure do |config|
  config.consumer_key = settings.config['pocket']['consumer_key']
end

helpers do
  def twitter()
    credentials = session[:twitter_credentials]
    Twitter::REST::Client.new do |config|
      config.consumer_key        = settings.config['twitter']['consumer_key']
      config.consumer_secret     = settings.config['twitter']['consumer_secret']
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
      in_reply_to = {
        :url => "https://twitter.com/%s/status/%s" %
          [status[:in_reply_to_screen_name], status[:in_reply_to_status_id_str]],
        :screen_name => status[:in_reply_to_screen_name],
        :id_str => status[:in_reply_to_status_id_str]
      }
    end
    result = {
      :id_str => status[:id_str],
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
        label = href.gsub(/([^0-9A-Za-z])/, '\1&#8203;') # zero-width-space: allows wrapping of long urls
        match = /^https:\/\/twitter\.com\/([^\/]+)\/status\/[0-9]+(\?|$)/.match(url[:expanded_url])
        if match
        then
          result.gsub! url[:url], "<button class=\"soc_tweet_link\" name=\"t\" value=\"#{href}\">[@#{match[1]} tweet]</button>"
        else
          result.gsub! url[:url], "<a href=\"#{href}\">#{label}</a><button class=\"soc_button\" name=\"a\" value=\"#{href}\">+</button>"
        end
      end
    end
    if status[:entities][:media]
      media = status[:entities][:media]
      if status[:extended_entities] and status[:extended_entities][:media]
        media = status[:extended_entities][:media]
      end
      media.each do |url|
        href = CGI::escapeHTML(url[:media_url_https])
        html = "<a href=\"#{href}\" class=\"soc_image_link\">[image]</a>"
        if !result.gsub! url[:url], html
          result += ' ' + html
        end
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

  def add_to_pocket(url, tweet_id)
    redis = Redis.new
    key = 'soc:uid:' + session[:uid] + ':pocket_access_token'
    access_token = redis.get(key)
    if access_token.nil?
      session[:pocket_add_url] = url
      redirect to('/auth/pocket')
      return false
    end
    pocket = Pocket.client(:access_token => access_token)
    pocket.add :url => url, :tweet_id => tweet_id
    true
  end
end

before do
  pass if request.path_info =~ /^\/auth\//
  redirect to('/auth/twitter') if session[:uid].nil?
end

get '/auth/failure' do
  'Login system failure'
end

get '/auth/info' do
  redis = Redis.new
  key = 'soc:uid:' + session[:uid] + ':pocket_access_token'
  pocket = redis.exists key
  haml :info, :locals => { :name => session[:name], 
                           :pocket => pocket,
                           :base => settings.config.fetch('base_path', '/') }
end

post '/auth/info' do
  if !params[:x].nil?
    session.clear
  elsif !params[:p].nil?
    redis = Redis.new
    key = 'soc:uid:' + session[:uid] + ':pocket_access_token'
    if redis.exists(key)
      redis.del key
    else
      redirect to('/auth/pocket')
      return
    end
  end
  redirect to(settings.config.fetch('base_path', '/'))
end

get '/auth/pocket' do
  callback = request.base_url + '/auth/pocket/callback'
  session[:pocket_code] = Pocket.get_code(:redirect_uri => callback)
  authorize_url = Pocket.authorize_url(
          :code => session[:pocket_code], :redirect_uri => callback)
  redirect authorize_url
end

get '/auth/pocket/callback' do
  access_token = Pocket.get_access_token(session[:pocket_code])
  redis = Redis.new
  key = 'soc:uid:' + session[:uid] + ':pocket_access_token'
  redis.set key, access_token
  redirect to(settings.config.fetch('base_path', '/'))
end

get '/auth/twitter/callback' do
  session[:uid] = env['omniauth.auth']['uid']
  session[:name] = env['omniauth.auth'][:info][:name]
  session[:utc_offset] = env['omniauth.auth'][:extra][:raw_info][:utc_offset]
  session[:twitter_credentials] = env['omniauth.auth']['credentials']
  redirect to(settings.config.fetch('base_path', '/'))
end

get '/' do
  status = get_status
  pocket_add_url = session[:pocket_add_url]
  if !pocket_add_url.nil?
    session[:pocket_add_url] = nil
    add_to_pocket pocket_add_url, status[:id_str]
    status[:message] = 'pocketed'
  end
  haml :root, :locals => status
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
  elsif !params[:u].nil?
    redirect to('/auth/info')
    return
  end
  status = get_status(delta)
  if !params[:a].nil?
    if add_to_pocket(params[:a], status[:id_str])
      status[:message] = 'pocketed'
    else
      return
    end
  end
  haml :root, :locals => status
end
