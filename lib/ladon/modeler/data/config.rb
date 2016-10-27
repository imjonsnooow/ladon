require 'securerandom'

module Ladon
  module Modeler
    class Config
      attr_accessor :id

      # Create a new Automator Config instance.
      def initialize(id: SecureRandom.uuid)
        @id = id
      end
    end
  end
end
