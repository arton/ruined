#!/usr/local/bin/ruby -Ku
# coding: utf-8

require 'webrick/log'

def run_app()
  argv = $DEBUG ? ['-d'] : []
  argv += ['-rruined/ruinmain', $0]
  argv += ARGV
  spawn "#{RbConfig::ruby}", *argv
end

def kill_child()
  open('http://localhost:8383/quit') do |h|
    h.read
  end
end

def quit_svr(c, svr)
  Thread.start do
    sleep(1)
    svr.shutdown
    puts 'svr stopped'
  end
end

if $0 == __FILE__
  $stderr.puts 'usage: ruby -ruined target [target-args]'
else
  require 'webrick'
  require 'open-uri'
  require 'mkmf'

  include WEBrick
  svr = HTTPServer.new(:Port => 8384,
                       :DocumentRoot => "#{File.dirname(__FILE__)}/ruined")
  trap('INT') do 
    svr.shutdown
  end
  svr.mount_proc('/restart') do |req, res|
    begin
      kill_child
    rescue
      svr.logger.error 'failed to kill child (restart)'
    end
    sleep(1.5)
    run_app
    res.body = '<html>restart</html>'
  end
  svr.mount_proc('/quit') do |req, res|
    begin
      kill_child
    rescue
      svr.logger.error 'failed to kill child (quit)'
    end
    c = 0
    if req.path =~ %r|/(\d+)|
      c = $1.to_i
    end
    quit_svr(c, svr)
    res.body = '<html>bye</html>'
  end
  svr.mount_proc('/connect') do |req, res|
    begin
      open('http://127.0.0.1:8383/debug/start') do |http|
        http.read
      end
    rescue
      res.status = 404
    end
    res.body = '<html></html>'
  end

  Thread.start do
    run_app
    if RUBY_PLATFORM =~ /win32/
      system('start http://localhost.:8384/html/index.html')
    elsif RUBY_PLATFORM =~ /cygwin/  
      system('cygstart http://localhost.:8384/html/index.html')      
    else
      system('open http://localhost.:8384/html/index.html')
    end
  end
  svr.start
  puts 'debugger exit'
  exit(0)
end
