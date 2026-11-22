# Redis de controle em memória, com a interface usada pelo AgentProfile, e que pode cair como o de verdade.
class FakeControlRedis
  attr_reader :writes

  def initialize
    @data = {}
    @writes = 0
  end

  def down! = @down = true

  def get(key) = check! && @data[key]
  def mget(*keys) = check! && keys.flatten.map { @data[_1] }

  def set(key, value)
    check!
    @writes += 1
    @data[key] = value
    "OK"
  end

  def del(key)
    check!
    @writes += 1
    @data.delete(key) ? 1 : 0
  end

  private

  def check!
    raise Redis::CannotConnectError, "Connection refused - connect(2) for 127.0.0.1:6379" if @down

    true
  end
end
