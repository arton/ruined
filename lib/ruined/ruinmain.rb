#!/usr/local/bin/ruby -Ku
# coding: utf-8

require 'webrick'
require 'json'
require 'thread'
require 'monitor'

module Ruined
  @queue = [Queue.new, Queue.new]
  @breakpoints = []
  @monitor = Monitor.new
  include WEBrick
  svr = HTTPServer.new(:Port => 8383,
                       :ServerType => Thread,
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

    def start(*a)
      '<html>start</html>'
    end
    
    private
    
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

  def self.wait(t)
    @monitor.synchronize {        
      unless @queue[t].empty?
        @queue[t].clear
    p "------------not wait exit #{t}"        
        return
      end
    }
    p "------------wait #{t}"
    @queue[t].pop
    p "------------wait exit #{t}"    
  end

  def self.release(t)
    p "------------release #{t}"    
    @monitor.synchronize {    
      @queue[t].push nil
    }
    p "------------release exit #{t}"        
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

  svr.start

  main_thread = Thread.current

  set_trace_func Proc.new {|event, file, line, id, binding, klass|
    unless file =~ /(webrick|internal)/ || main_thread != Thread.current
      if event.index('c-') != 0
        b = breakpoints.include? [file, line]
        @current = { 'event' => event, 'file' => file, 'line' => line, 
          'id' => id.to_s, 'break' => b }
        p @current
        release 1
        wait 0
        p 'continue...'
      end
    end
  }
end

