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
require 'http/cookie'
require 'net/http'
require 'nokogiri'
require 'omniauth-twitter'
require 'pocket-ruby'
require 'rack/session/redis'
require 'redis'
require 'sinatra'
require 'twitter'
require 'uri'
require 'yaml'

def fetch(uri_str, limit = 10, jar = nil)
  raise ArgumentError, 'too many HTTP redirects' if limit == 0
  $stderr.print "INFO: fetching " + uri_str + "\n"

  cookie = HTTP::Cookie.cookie_value(jar.cookies(uri_str)) if jar
  uri = URI(uri_str)
  request = Net::HTTP::Get.new uri
  request['Accept'] = '*/*'
  request['Cookie'] = cookie if cookie
  request['Host'] = uri.host
  request['User-Agent'] = 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:40.0) Gecko/20100101 Firefox/40.0'
  client = Net::HTTP.new(uri.host, uri.port)
  client.use_ssl = (uri.scheme == 'https')
  response = client.start do |http|
    http.request request
  end
  headers = response.get_fields('Set-Cookie') if jar
  if headers
    headers.each { |value|
      jar.parse(value, uri)
    }
  end

  case response
  when Net::HTTPSuccess then
    response
  when Net::HTTPRedirection then
    location = response['location']
    fetch(location, limit - 1, jar)
  else
    response.value
  end
end

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

  def follow(status, follow_url)
    while true
      retweet = status[:retweeted_status]
      break if not retweet
      status = retweet
    end
    if status[:entities][:urls]
      status[:entities][:urls].each do |url|
        if url[:expanded_url] == follow_url
          begin
            jar = HTTP::CookieJar.new
            response = fetch(follow_url, 10, jar)
            url[:expanded_url] = response.uri.to_s
          rescue StandardError => e
            $stderr.print "ERROR: cannot open " + follow_url + " " + e.to_s + "\n"
          end
          begin
            html = response.body
            doc = Nokogiri::HTML(html)
            titles = doc.xpath('//title')
            title = titles[0]
            url[:title] = title ? title.content.strip : '?'
          rescue StandardError => e
            $stderr.print "ERROR: cannot load " + follow_url + " " + e.to_s + "\n"
          end
        end
      end
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
    id_str = status[:id_str]
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
      :id_str => id_str,
      :contexts => contexts,
      :content_html => format_content_html(status),
      :message => message,
      :in_reply_to => in_reply_to
    }
  end

  def format_urls(status)
    result = {}
    if status[:entities][:urls]
      status[:entities][:urls].each do |entity|
        href = CGI::escapeHTML(entity[:expanded_url])
        html = href
        match = /^https:\/\/(((m)|(www))\.)?twitter\.com\/([^\/]+)\/status\/[0-9]+(\?|$)/.match(entity[:expanded_url])
        if match
        then
          html = "<button class=\"soc_tweet_link\" name=\"t\" value=\"#{href}\">[@#{match[5]} tweet]</button>"
        else
          if entity[:title]
            html = "<a href=\"#{href}\" class=\"soc_link\">#{href}</a>" +
                  "<button class=\"soc_button\" name=\"a\" value=\"#{href}\">+</button>" +
                  "[#{entity[:title]}]"
          else
            html = "<a href=\"#{href}\" class=\"soc_link\">#{href}</a>" +
                  "<button class=\"soc_button\" name=\"a\" value=\"#{href}\">+</button>" +
                  "<button class=\"soc_button\" name=\"i\" value=\"#{href}\">?</button>"
          end
        end
        entity[:html] = html
        if not result.key?(entity[:indices][0])
          result[entity[:indices][0]] = []
        end
        result[entity[:indices][0]].push(entity)
      end
    end
    result
  end

  def format_media(status)
    result = {}
    if status[:entities][:media]
      media = status[:entities][:media]
      if status[:extended_entities] and status[:extended_entities][:media]
        media = status[:extended_entities][:media]
      end
      media.each do |entity|
        href = CGI::escapeHTML(entity[:media_url_https])
        html = href
        if entity[:type] == 'video' or entity[:type] == 'animated_gif'
            html = "<a href=\"#{href}\" class=\"soc_video_link\">[video]</a>"
        else
            html = "<a href=\"#{href}\" class=\"soc_image_link\">[image]</a>"
        end
        entity[:html] = html
        if not result.key?(entity[:indices][0])
          result[entity[:indices][0]] = []
        end
        result[entity[:indices][0]].push(entity)
      end
    end
    result
  end

  def format_mentions(status)
    result = {}
    if status[:entities][:user_mentions]
      status[:entities][:user_mentions].each do |entity|
        entity[:html] =
          "<a href=\"https://twitter.com/#{CGI::escapeHTML(entity[:screen_name])}\"" +
          " title=\"#{CGI::escapeHTML(entity[:name])}\">" +
          "@#{CGI::escapeHTML(CGI::escapeHTML(entity[:screen_name]))}</a>"
        if not result.key?(entity[:indices][0])
          result[entity[:indices][0]] = []
        end
        result[entity[:indices][0]].push(entity)
      end
    end
    result
  end

  def format_content_html(status)
    result = status[:full_text]
    entities = format_urls(status)
    entities.update format_media(status)
    entities.update format_mentions(status)
    entities.sort.reverse!.each do |pair|
      edits = pair[1]
      result.slice!(edits[0][:indices][0], edits[0][:indices][1] - edits[0][:indices][0])
      edits.reverse!.each do |entity|
        result.insert(entity[:indices][0], entity[:html])
      end
    end
    result
  end

  def get_status(delta = 0, rel_id = nil)
    redis = Redis.new
    status_key = 'soc:uid:' + session[:uid] + ':statuses'
    count = redis.llen status_key
    index_key = 'soc:uid:' + session[:uid] + ':status_index'
    index = (redis.get index_key).to_i
    id_key = 'soc:uid:' + session[:uid] + ':status_id'
    if delta != 0 and rel_id == (redis.get id_key)
      if delta == Float::INFINITY
        index = (index < count - 1) ? (count - 1) : count
      elsif delta == -Float::INFINITY
        index = (index > 0) ?  0 : -1
      else
        index += delta
      end
    end
    if index < 0
      string = redis.lindex(status_key, 0)
      if string.nil?
        begin
          new = twitter().home_timeline :count => 200, :tweet_mode => 'extended'
        rescue
          $stderr.print "ERROR: home_timeline - " + $!.to_s + "\n"
        end
      else
        top = Marshal.load string
        # include refetch newest cached tweet to see if we missed any
        since = top.id - 1
        begin
          new = twitter().home_timeline :count => 200, :tweet_mode => 'extended', :since_id => since
        rescue
          $stderr.print "ERROR: home_timeline since_id => " + since + " - " + $!.to_s + "\n"
        end
        #if top.id != new[-1].id
        #   LATER: 
        #end
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
        begin
          new = twitter().home_timeline :count => 200, :tweet_mode => 'extended'
        rescue
          $stderr.print "ERROR: home_timeline - " + $!.to_s + "\n"
        end
      else
        bottom = Marshal.load string
        max = bottom.id
        begin
          new = twitter().home_timeline :count => 200, :tweet_mode => 'extended', :max_id => max
        rescue
          $stderr.print "ERROR: home_timeline max_id => " + max + " - " + $!.to_s + "\n"
        end
      end
      if !new.nil? and new.length > 0
        strings = new.map { |item| Marshal.dump item }
        count = redis.rpush(status_key, strings)
      end
    end
    index = [0, [index, count].min].max
    redis.set index_key, index
    status = Marshal.load redis.lindex(status_key, index)
    redis.set id_key, status.attrs[:id_str]
    redis.disconnect!
    format_status status.attrs, index
  end

  def get_status_by_id(tweet_id, follow_url = nil)
    begin
      status = twitter().status tweet_id, :tweet_mode => 'extended'
    rescue
      $stderr.print "ERROR: status(" + params[:t] + ") - " + $!.to_s + "\n"
    end
    if status
      id_key = 'soc:uid:' + session[:uid] + ':status_id'
      redis = Redis.new
      redis.set id_key, status.attrs[:id_str]
      redis.disconnect!
      follow(status.attrs, follow_url) if follow_url
      return format_status(status.attrs)
    end
    return false
  end

  def add_to_pocket(url, tweet_id)
    key = 'soc:uid:' + session[:uid] + ':pocket_access_token'
    redis = Redis.new
    access_token = redis.get(key)
    redis.disconnect!
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
  if session[:uid]
    key = 'soc:uid:' + session[:uid] + ':pocket_access_token'
    redis = Redis.new
    pocket = redis.exists key
    redis.disconnect!
  end
  haml :info, :locals => { :name => session[:name],
                           :pocket => pocket,
                           :base => settings.config.fetch('base_path', '/') }
end

post '/auth/info' do
  if !params[:x].nil?
    session.clear
    redirect 'https://twitter.com/logout'
    return
  elsif !params[:p].nil?
    redis = Redis.new
    key = 'soc:uid:' + session[:uid] + ':pocket_access_token'
    if redis.exists(key)
      redis.del key
      redis.disconnect!
    else
      redis.disconnect!
      redirect to('/auth/pocket')
      return
    end
  elsif !params[:i].nil?
    session[:night] = !session[:night]
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
  redis.disconnect!
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
    status = get_status_by_id(params[:t])
    if status
      return haml :root, :locals => status
    end
  elsif !params[:i].nil?
    status = get_status_by_id(params[:id], params[:i])
    if status
      return haml :root, :locals => status
    end
  elsif !params[:u].nil?
    redirect to('/auth/info')
    return
  end
  status = get_status(delta, params[:id])
  if !params[:a].nil?
    if add_to_pocket(params[:a], params[:id])
      status[:message] = 'pocketed'
    else
      return
    end
  end
  haml :root, :locals => status
end
