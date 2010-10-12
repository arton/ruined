#!/usr/local/bin/ruby
# coding: utf-8

require 'webrick'
require 'json'
require 'thread'
require 'monitor'
require 'stringio'

module Ruined
  RUINED_VERSION = '0.0.4'
  
  @queue = [Queue.new, Queue.new]
  @breakpoints = []
  @monitor = Monitor.new
  @tlses = { '$!' => nil, '$?' => nil, '$@' => nil, '$SAFE' => nil}
  IGNORES = [:$&, :$', :$+, :$_, :$`, :$~, :$KCODE, :$= ]
  
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
      if req.addr[3] == '127.0.0.1'      
        super
      else
        bye(res)
      end
    end
    def do_GET(req, res)
      m = %r|/debug/([^/]+)/?(.*)\Z|.match(req.path)
      if m
        res.body = __send__(m[1].to_sym, *(m[2].split('/')))
      else
        bye(res)        
      end
    end

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
      JSON(Ruined.current)
    end

    def cont(*a)
      Ruined.release 0
      Ruined.wait 1
      JSON(Ruined.current)
    end

    def step(*a)
      cont(a)
    end
        
    def file(*a)
      r = '<table>'
      File.open(a.join('/')).each_line do |line|
        r << "<tr><td><pre>#{escape(line)}</pre></td></tr>"
      end.close
      r + '</table>'
    end
    
    def locals(*a)
      if a.size == 0
        create_varlist Ruined.local_vars
      elsif a.size != 2
        bye(response)
      else
        Ruined.set(a[0], a[1]).to_s
      end
    end
    
    def globals(*a)
      if a.size == 0
        create_varlist Ruined.global_vars
      elsif a.size != 2
        bye(response)
      else
        Ruined.set(a[0], a[1]).to_s
      end
    end

    def self(*a)
      if a.size == 0
        create_varlist Ruined.self_vars
      elsif a.size != 2
        bye(response)
      else
        Ruined.set(a[0], a[1]).to_s
      end
    end
    
    def start(*a)
      '<html>start</html>'
    end
    
    private
    
    def create_varlist(t)
      s = '<table class="vars"><tr><th>Name</th><th>Value</th></tr>'
      t.each do |e|
        s << "<tr><td>#{e[:name]}</td><td class=\"var-value\">#{escape(e[:value].inspect)}</td></tr>"
      end
      s + '</table>'
    end
    
    def bye(res)
      res.status = 404
      res.body = '<html>bye</html>'
    end
  end

  def self.current
    @current
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
    @current_binding ? eval(script, @current_binding) : []
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
    @current_binding ? eval(script, @current_binding) : []
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
    0.upto(a.size - 1) do |i|
      if @tlses.has_key?(a[i][:name])
        a[i][:value] = @tlses[a[i][:name]]
      end
    end
    a
  end
  
  def self.set(var, val)
    eval("#{var} = #{val}", @current_binding)
  end
  
  def self.tls_vars
    @@tlses
  end

  def self.wait(t)
    @monitor.synchronize {        
      unless @queue[t].empty?
        @queue[t].clear
        logger.debug("------------not wait exit #{t}")
        return
      end
    }
    logger.debug("------------wait #{t}")
    @queue[t].pop
    logger.debug("------------wait exit #{t}")
  end

  def self.release(t)
    logger.debug("------------release #{t}")
    @monitor.synchronize {    
      @queue[t].push nil
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
      ret << "#{x.chomp}<br/>"
    end
    ret
  end

  svr.mount('/debug', DebugServlet)
  svr.mount_proc('/quit') do |req, res|
    if req.addr[3] == '127.0.0.1'
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

  main_thread = Thread.current

  set_trace_func Proc.new {|event, file, line, id, binding, klass|
    unless file =~ %r#(lib/ruby|webrick|internal)# || main_thread != Thread.current
      if event.index('c-') != 0
        if file == $0 && !$stdout.instance_of?(StringIO)
          $stdout = StringIO.new
        end
        @tlses.each do |k, v|
          @tlses[k] = eval(k)
        end
        b = breakpoints.include? [file, line]
        @current_binding = binding
        @current = { 'event' => event, 'file' => file, 'line' => line, 
          'id' => id.to_s, 'break' => b, 'stdout' => output }
        svr.logger.debug(@current.inspect)
        release 1
        wait 0
        svr.logger.debug('continue...')
      end
    end
  }
  at_exit { 
    if @current
      @current['event'] = 'exit'
      @current['stdout'] = output
      release 1
      wait 0
    end
  }
end

