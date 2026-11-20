module AgentMock
  # Relógio e espera reais. Nos testes entra um relógio falso, que avança sem sleep (RNF-30).
  module SystemClock
    module_function

    def call = Time.now.utc
    def sleep(seconds) = Kernel.sleep(seconds)
  end
end
