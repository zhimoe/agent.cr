require "json"

class Agent
  # A tool definition that matches the OpenAI tools API.
  class Tool
    getter function : FunctionDef

    def initialize(@function : FunctionDef)
    end

    # Chat Completions shape: `{"type":"function","function":{...}}`.
    def to_chat_json : JSON::Any
      fn = {} of String => JSON::Any
      fn["name"] = JSON::Any.new(@function.name)
      fn["description"] = JSON::Any.new(@function.description || "")
      fn["parameters"] = JSON::Any.new(@function.parameters || {} of String => JSON::Any)
      strict = @function.strict
      fn["strict"] = JSON::Any.new(strict) unless strict.nil?
      JSON::Any.new({
        "type"     => JSON::Any.new("function"),
        "function" => JSON::Any.new(fn),
      })
    end

    # Responses API shape: function fields are flat.
    def to_responses_json : JSON::Any
      body = {} of String => JSON::Any
      body["type"] = JSON::Any.new("function")
      body["name"] = JSON::Any.new(@function.name)
      body["description"] = JSON::Any.new(@function.description || "")
      body["parameters"] = JSON::Any.new(@function.parameters || {} of String => JSON::Any)
      strict = @function.strict
      body["strict"] = JSON::Any.new(strict) unless strict.nil?
      JSON::Any.new(body)
    end

    class FunctionDef
      getter name : String
      getter description : String?
      getter parameters : Hash(String, JSON::Any)?
      getter strict : Bool?

      def initialize(
        @name : String,
        @description : String? = nil,
        @parameters : Hash(String, JSON::Any)? = nil,
        @strict : Bool? = nil,
      )
      end
    end
  end
end
