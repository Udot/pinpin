require "remote_syslog_logger"
class RemoteSyslog
  def initialize(host, port)
    @logger = RemoteSyslogLogger.new(host, port, {:program => 'pinpin'})
  end

  def info(msg)
    @logger.info(msg)
  end
  def error(msg)
    @logger.error(msg)
  end
  def warn(msg)
    @logger.warn(msg)
  end

  def write(str)
    @logger.info(str)
  end
end