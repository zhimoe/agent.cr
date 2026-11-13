require "../base"

class Agent
  module Provider
    class OpenAI < Base
      # Provider-level configuration is now the single user-facing
      # Agent::Config. The alias keeps `Provider::OpenAI::Config.new(...)`
      # source-compatible.
      alias Config = Agent::Config
    end
  end
end
