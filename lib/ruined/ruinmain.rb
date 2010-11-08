#!/usr/local/bin/ruby
# coding: utf-8

require 'webrick'
require 'uri'
require 'json'
require 'thread'
require 'monitor'
require 'stringio'
require 'fileutils'

module Ruined
  RUINED_VERSION = '0.1.0'
  
  @queue = [Queue.new, Queue.new]
  @breakpoints = []
  @monitor = Monitor.new
  IGNORES = [:$&, :$', :$+, :$_, :$`, :$~, :$KCODE, :$= ]
  @unbreakable_threads = []
  @user_threads = { }

  class <<Thread
    alias :_original_start :start
    def start(&proc)
      webrick = caller.first.include?('webrick')
      $stderr.puts "caller=#{caller[2]}, webrick=#{webrick}"
      $stderr.flush
      _original_start do
        Ruined.add_unbreakable(Thread.current) if webrick
        begin
          proc.call
        ensure
          Ruined.remove_unbreakable(Thread.current) if webrick    
        end
      end  
    end
  end
  
  class Context
    TLSES = ['$!', '$?', '$@', '$SAFE']
    def initialize(e, f, l, id, bnd, b, s)
      @event = e
      @file = f
      @line = l
      @iid = id.to_s
      @break = b
      @binding = bnd
      @stdout = s
      @tlses = Hash[*(TLSES.map{|k| [k, eval(k)]}.flatten(1))]
    end
    def to_hash
      { :event => @event, :file => @file, :line => @line, :id => @iid, :break => @break,
        :stdout => @stdout, :threads => Ruined.user_threads(self) }
    end
    attr_reader :tlses, :file, :line, :iid, :binding, :break
    attr_accessor :event, :stdout
  end

  include WEBrick
  svr = HTTPServer.new(:Port => 8383,
                       :ServerType => Thread,
                       :Logger => ($DEBUG) ? Log.new(nil, BasicLog::DEBUG) : Log.new,
                       :DocumentRoot => File.dirname(__FILE__))
  trap('INT') do 
    svr.shutdown
  end
  
  class DebugServlet <  HTTPServlet::AbstractServlet
    include WEBrick::HTMLUtils
    def service(req, res)
      if Ruined.local_call?(req.addr)
        @response = res
        @request = req
        super
        @response = nil
        @request = nil
      else
        bye(res)
      end
    end
    def do_GET(req, res)
      m = %r|/debug/([^/?]+)/?([^?]*).*\Z|.match(req.unparsed_uri)
      if m
        res.body = __send__(m[1].to_sym, *(m[2].split('/').map{|x|URI.decode(x)}))
      else
        bye(res)        
      end
    end
    def do_POST(req, res)
      m = %r|/debug/([^/?]+)/?([^?]*).*\Z|.match(req.unparsed_uri)
      if m && m[1] == 'file'
        res.body = __send__(m[1].to_sym, *(m[2].split('/').map{|x|URI.decode(x)}))
      else
        bye(res)        
      end
    end

    attr_reader :response, :request

    def break(*a)
      if a.size < 3
        bye(response)
      else
        point = [a[1..(a.size - 2)].join('/'), a[a.size - 1].to_i]
        if a[0] == 'true'
          Ruined.breakpoints << point
        else
          Ruined.breakpoints.delete point
        end
        JSON(point)
      end
    end

    def run(*a)
    end

    def stop(*a)
    end

    def stepping(*a)
      Ruined.wait 1      
      JSON(Ruined.current_context)
    end

    def cont(*a)
      Ruined.release 0
      Ruined.wait 1
      JSON(Ruined.current_context)
    end

    def step(*a)
      cont(a)
    end
        
    def file(*a)
      file = a.join('/')
      if request.request_method == 'GET'
        request.accept.each do |accept|
          if accept =~ /html/i
            break
          elsif accept =~ %r|text/plain|i
            File.open(file) do |f|
              return Ruined::to_utf8(f.read)
            end
          end
        end
        to_html(file)
      else
        # TODO: newline and charset justify
        # wb is workaround for inhibit to put addition \r
        File.open("#{file}.new", 'wb') do |f|
          f.write(request.body)
        end
        FileUtils.cp file, "#{file}.bak", :verbose => true
        FileUtils.cp "#{file}.new", file, :verbose => true
        FileUtils.rm "#{file}.new"
        "save #{file}"
      end  
    end
    
    def locals(*a)
      if a.size == 0
        create_varlist Ruined.local_vars
      else
        eval_var(a)
      end
    end
    
    def globals(*a)
      if a.size == 0
        create_varlist Ruined.global_vars
      else
        eval_var(a)
      end
    end

    def self(*a)
      if a.size == 0
        create_varlist Ruined.self_vars
      elsif a.size < 2
        bye(response)
      else
        eval_var(a)
      end
    end
    
    def start(*a)
      '<html>start</html>'
    end
    
    private
    
    def create_varlist(t)
      s = '<table class="vars"><tr><th>Name</th><th>Value</th></tr>'
      t.each do |e|
        v = Ruined.to_utf8(e[:value].inspect)
        s << "<tr><td>#{e[:name]}</td><td class=\"var-value\">#{escape(v)}</td></tr>"
      end
      s + '</table>'
    end

    def eval_var(a)
      if a.size < 2
        bye(response)
      else
        Ruined.set(a[0], a[1..-1].join('/')).to_s
      end
    end
    
    def to_html(file)
      r = '<table>'
      File.open(file).each_line do |line|
        r << "<tr><td><pre>#{escape(Ruined::to_utf8(line))}</pre></td></tr>"
      end.close
      r + '</table>'
    end
    
    def bye(res)
      res.status = 404
      res.body = '<html>bye</html>'
    end
  end

  def self.current_context
    raise RuntimeException.new('bug: no context !!') unless @current
    @current.to_hash
  end
  
  def self.breakpoints
    @breakpoints
  end
  
  def self.local_vars
    script = <<EOD
local_variables.map do |_0|
  (_0 == :_) ? nil : { :name => _0.to_s, :value => eval(_0.to_s) }
end - [nil]
EOD
    (@current) ? eval(script, @current.binding) : []
  end
  
  def self.self_vars
    script = <<EOD
[{ :name => 'class', :value => self.class.to_s }] +
instance_variables.map do |v|
  { :name => v.to_s, :value => instance_eval(v.to_s) }
end +
self.class.class_variables.map do |v|
  { :name => v.to_s, :value => instance_eval(v.to_s) }
end
EOD
    (@current) ? eval(script, @current.binding) : []    
  end
  
  def self.global_vars
    script = <<EOD
(global_variables - Ruined::IGNORES).map do |v|
  if v.to_s =~ /\\A\\$[1-9]/
    nil
  else
    { :name => v.to_s, :value => eval(v.to_s) }
  end
end - [nil]
EOD
    a = eval(script)
    if @current
      0.upto(a.size - 1) do |i|
        if @current.tlses.has_key?(a[i][:name])
          a[i][:value] = @current.tlses[a[i][:name]]
        end
      end
    end
    a
  end
  
  def self.set(var, val)
    eval("#{var} = #{val}", @current.binding)
  end
  
  def self.wait(t)
    return unless @queue    
    logger.debug("------------wait #{t}")
    o = @queue[t].pop
    if t == 1
      @current = o
    end
    logger.debug("------------wait exit #{t}")
  end

  def self.release(t, obj = nil)
    return unless @queue
    logger.debug("------------release #{t}")
    @monitor.synchronize {    
      @queue[t].push obj
    }
    logger.debug("------------release exit #{t}")
  end
  
  def self.output
    return '' unless StringIO === $stdout
    out = $stdout
    $stdout = StringIO.new
    out.pos = 0
    ret = ''
    out.each_line do |x|
      ret << "#{HTMLUtils.escape(to_utf8(x.chomp))}<br/>"
    end
    ret
  end
  
  def self.to_utf8(s)
    (s.encoding != Encoding::UTF_8) ? s.encode(Encoding::UTF_8) : s
  end
  
  def self.add_unbreakable(t)
    @monitor.synchronize {
      @unbreakable_threads << t
    }
  end
  
  def self.remove_unbreakable(t)
    @monitor.synchronize {
      @unbreakable_threads.delete t
    }
  end
  
  def self.unbreakable?(t)
    @monitor.synchronize {
      @unbreakable_threads.include? t
    }
  end
  
  def self.local_call?(addr)
    ['127.0.0.1', '::1'].include?(addr[3])
  end
  
  def self.user_threads(current)
    r = []
    @monitor.synchronize {                
      @user_threads.each do |t, c|
        r << [:file => File.basename(c.file), :line => c.line, 
              :self => (c == current),
              :status => status_to_s(t.status)]
      end
      r
    }
  end
  
  def self.status_to_s(s)
    if s.nil?
      'aborted'
    elsif s == false
      'dead'
    else
      s
    end
  end

  svr.mount('/debug', DebugServlet)
  svr.mount_proc('/quit') do |req, res|
    if local_call?(req.addr)
      set_trace_func(nil)
      c = 0
      if req.path =~ %r|/(\d+)|
        c = $1.to_i
      end
      res.body = '<html>bye</html>'
      Thread.start do
        @monitor.synchronize {        
          @queue = nil
        }
        Thread.pass
        svr.shutdown
        exit(c)
      end
    else
      res.status = 404
    end
  end
  
  define_method(:logger) do
    return svr.logger
  end
  module_function(:logger)

  svr.start

  set_trace_func Proc.new {|event, file, line, id, binding, klass|
    unless file =~ %r#(lib/ruby|ruinmain|webrick|internal)# || unbreakable?(Thread.current)
      if event.index('c-') != 0
        if file == $0 && !$stdout.instance_of?(StringIO)
          $stdout = StringIO.new
        end
        b = breakpoints.include? [file, line]
        ctxt = @monitor.synchronize {            
          @user_threads[Thread.current] = Context.new(event, file, line, id, binding, b, output)
        }
        svr.logger.debug(ctxt.inspect)
        release 1, ctxt
        wait 0
        svr.logger.debug('continue...')
      end
    end
  }
  at_exit { 
    if @current
      @current.event = 'exit'
      @current.stdout = output
      release 1, @current #reschedule
      wait 0
    end
  }
end
