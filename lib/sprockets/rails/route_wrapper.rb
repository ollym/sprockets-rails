module Sprockets
  module Rails
    module RouteWrapper
      def internal_sprockets_path?
        path =~ %r{\A#{self.class.sprockets_prefix}\z}
      end

      def internal?
        super || internal_sprockets_path?
      end
    end
  end
end
