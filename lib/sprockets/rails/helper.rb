require 'action_view'
require 'sprockets'
require 'active_support/core_ext/class/attribute'
require 'sprockets/rails/utils'

module Sprockets
  module Rails
    module Helper
      class AssetNotFound < StandardError; end
      class AssetNotPrecompiled < StandardError; end

      class AssetNotPrecompiledError < AssetNotPrecompiled
        include Sprockets::Rails::Utils
        def initialize(source)
          msg =
          if using_sprockets4?
            "Asset `#{ source }` was not declared to be precompiled in production.\n" +
            "Declare links to your sprockets in `app/sprockets/config/manifest.js`.\n\n" +
            "  //= link #{ source }\n\n" +
            "and restart your server"
          else
            "Asset was not declared to be precompiled in production.\n" +
            "Add `Rails.application.config.sprockets.precompile += " +
            "%w( #{source} )` to `config/initializers/sprockets.rb` and " +
            "restart your server"
          end
          super(msg)
        end
      end

      include ActionView::Helpers::AssetUrlHelper
      include ActionView::Helpers::AssetTagHelper
      include Sprockets::Rails::Utils

      VIEW_ACCESSORS = [
        :sprockets_environment, :sprockets_manifest,
        :sprockets_precompile, :precompiled_asset_checker,
        :sprockets_prefix, :digest_sprockets, :debug_sprockets,
        :resolve_sprockets_with, :check_precompiled_asset,
        :unknown_asset_fallback
      ]

      def self.included(klass)
        klass.class_attribute(*VIEW_ACCESSORS)

        klass.class_eval do
          remove_method :sprockets_environment
          def sprockets_environment
            if instance_variable_defined?(:@sprockets_environment)
              @sprockets_environment = @sprockets_environment.cached
            elsif env = self.class.sprockets_environment
              @sprockets_environment = env.cached
            else
              nil
            end
          end
        end
      end

      def self.extended(obj)
        obj.singleton_class.class_eval do
          attr_accessor(*VIEW_ACCESSORS)

          remove_method :sprockets_environment
          def sprockets_environment
            if env = @sprockets_environment
              @sprockets_environment = env.cached
            else
              nil
            end
          end
        end
      end

      # Writes over the built in ActionView::Helpers::AssetUrlHelper#compute_asset_path
      # to use the asset pipeline.
      def compute_asset_path(path, options = {})
        debug = options[:debug]

        if asset_path = resolve_asset_path(path, debug)
          File.join(sprockets_prefix || "/", legacy_debug_path(asset_path, debug))
        else
          message =  "The asset #{ path.inspect } is not present in the asset pipeline.\n"
          raise AssetNotFound, message unless unknown_asset_fallback

          if respond_to?(:public_compute_asset_path)
            message << "Falling back to an asset that may be in the public folder.\n"
            message << "This behavior is deprecated and will be removed.\n"
            message << "To bypass the asset pipeline and preserve this behavior,\n"
            message << "use the `skip_pipeline: true` option.\n"

            Sprockets::Rails.deprecator.warn(message, caller_locations)
          end
          super
        end
      end

      # Resolve the asset path against the Sprockets manifest or environment.
      # Returns nil if it's an asset we don't know about.
      def resolve_asset_path(path, allow_non_precompiled = false) #:nodoc:
        resolve_asset do |resolver|
          resolver.asset_path path, digest_sprockets, allow_non_precompiled
        end
      end

      # Expand asset path to digested form.
      #
      # path    - String path
      # options - Hash options
      #
      # Returns String path or nil if no asset was found.
      def asset_digest_path(path, options = {})
        resolve_asset do |resolver|
          resolver.digest_path path, options[:debug]
        end
      end

      # Experimental: Get integrity for asset path.
      #
      # path    - String path
      # options - Hash options
      #
      # Returns String integrity attribute or nil if no asset was found.
      def asset_integrity(path, options = {})
        path = path_with_extname(path, options)

        resolve_asset do |resolver|
          resolver.integrity path
        end
      end

      # Override javascript tag helper to provide debugging support.
      #
      # Eventually will be deprecated and replaced by source maps.
      def sprockets_javascript_include_tag(*sources)
        options = sources.extract_options!.stringify_keys
        integrity = compute_integrity?(options)

        if options["debug"] != false && request_debug_sprockets?
          sources.map { |source|
            if asset = lookup_debug_asset(source, type: :javascript)
              if asset.respond_to?(:to_a)
                asset.to_a.map do |a|
                  javascript_include_tag(path_to_javascript(a.logical_path, debug: true), options)
                end
              else
                javascript_include_tag(path_to_javascript(asset.logical_path, debug: true), options)
              end
            else
              javascript_include_tag(source, options)
            end
          }.flatten.uniq.join("\n").html_safe
        else
          sources.map { |source|
            options = options.merge('integrity' => asset_integrity(source, type: :javascript)) if integrity
            javascript_include_tag source, options
          }.join("\n").html_safe
        end
      end

      # Override stylesheet tag helper to provide debugging support.
      #
      # Eventually will be deprecated and replaced by source maps.
      def sprockets_stylesheet_link_tag(*sources)
        options = sources.extract_options!.stringify_keys
        integrity = compute_integrity?(options)

        if options["debug"] != false && request_debug_sprockets?
          sources.map { |source|
            if asset = lookup_debug_asset(source, type: :stylesheet)
              if asset.respond_to?(:to_a)
                asset.to_a.map do |a|
                  stylesheet_link_tag(path_to_stylesheet(a.logical_path, debug: true), options)
                end
              else
                stylesheet_link_tag(path_to_stylesheet(asset.logical_path, debug: true), options)
              end
            else
              stylesheet_link_tag(source, options)
            end
          }.flatten.uniq.join("\n").html_safe
        else
          sources.map { |source|
            options = options.merge('integrity' => asset_integrity(source, type: :stylesheet)) if integrity
            stylesheet_link_tag source, options
          }.join("\n").html_safe
        end
      end

      protected
        # This is awkward: `integrity` is a boolean option indicating whether
        # we want to include or omit the subresource integrity hash, but the
        # options hash is also passed through as literal tag attributes.
        # That means we have to delete the shortcut boolean option so it
        # doesn't bleed into the tag attributes, but also check its value if
        # it's boolean-ish.
        def compute_integrity?(options)
          if secure_subresource_integrity_context?
            case options['integrity']
            when nil, false, true
              options.delete('integrity') == true
            end
          else
            options.delete 'integrity'
            false
          end
        end

        # Only serve integrity metadata for HTTPS requests:
        #   http://www.w3.org/TR/SRI/#non-secure-contexts-remain-non-secure
        def secure_subresource_integrity_context?
          respond_to?(:request) && self.request && (self.request.local? || self.request.ssl?)
        end

        # Enable split asset debugging. Eventually will be deprecated
        # and replaced by source maps in Sprockets 3.x.
        def request_debug_sprockets?
          debug_sprockets || (defined?(controller) && controller && params[:debug_sprockets])
        rescue # FIXME: what exactly are we rescuing?
          false
        end

        # Internal method to support multifile debugging. Will
        # eventually be removed w/ Sprockets 3.x.
        def lookup_debug_asset(path, options = {})
          path = path_with_extname(path, options)

          resolve_asset do |resolver|
            resolver.find_debug_asset path
          end
        end

        # compute_asset_extname is in AV::Helpers::AssetUrlHelper
        def path_with_extname(path, options)
          path = path.to_s
          "#{path}#{compute_asset_extname(path, options)}"
        end

        # Try each asset resolver and return the first non-nil result.
        def resolve_asset
          asset_resolver_strategies.detect do |resolver|
            if result = yield(resolver)
              break result
            end
          end
        end

        # List of resolvers in `config.sprockets.resolve_with` order.
        def asset_resolver_strategies
          @asset_resolver_strategies ||=
            Array(resolve_sprockets_with).map do |name|
              HelperAssetResolvers[name].new(self)
            end
        end

        # Append ?body=1 if debug is on and we're on old Sprockets.
        def legacy_debug_path(path, debug)
          if debug && !using_sprockets4?
            "#{path}?body=1"
          else
            path
          end
        end
    end

    # Use a separate module since Helper is mixed in and we needn't pollute
    # the class namespace with our internals.
    module HelperAssetResolvers #:nodoc:
      def self.[](name)
        case name
        when :manifest
          Manifest
        when :environment
          Environment
        else
          raise ArgumentError, "Unrecognized asset resolver: #{name.inspect}. Expected :manifest or :environment"
        end
      end

      class Manifest #:nodoc:
        def initialize(view)
          @manifest = view.sprockets_manifest
          raise ArgumentError, 'config.sprockets.resolve_with includes :manifest, but app.sprockets_manifest is nil' unless @manifest
        end

        def asset_path(path, digest, allow_non_precompiled = false)
          if digest
            digest_path path, allow_non_precompiled
          end
        end

        def digest_path(path, allow_non_precompiled = false)
          @manifest.sprockets[path]
        end

        def integrity(path)
          if meta = metadata(path)
            meta["integrity"]
          end
        end

        def find_debug_asset(path)
          nil
        end

        private
          def metadata(path)
            if digest_path = digest_path(path)
              @manifest.files[digest_path]
            end
          end
      end

      class Environment #:nodoc:
        def initialize(view)
          raise ArgumentError, 'config.sprockets.resolve_with includes :environment, but app.sprockets is nil' unless view.sprockets_environment
          @env = view.sprockets_environment
          @precompiled_asset_checker = view.precompiled_asset_checker
          @check_precompiled_asset = view.check_precompiled_asset
        end

        def asset_path(path, digest, allow_non_precompiled = false)
          # Digests enabled? Do the work to calculate the full asset path.
          if digest
            digest_path path, allow_non_precompiled

          # Otherwise, ask the Sprockets environment whether the asset exists
          # and check whether it's also precompiled for production deploys.
          elsif asset = find_asset(path)
            raise_unless_precompiled_asset asset.logical_path unless allow_non_precompiled
            path
          end
        end

        def digest_path(path, allow_non_precompiled = false)
          if asset = find_asset(path)
            raise_unless_precompiled_asset asset.logical_path unless allow_non_precompiled
            asset.digest_path
          end
        end

        def integrity(path)
          find_asset(path).try :integrity
        end

        def find_debug_asset(path)
          if asset = find_asset(path, pipeline: :debug)
            raise_unless_precompiled_asset asset.logical_path.sub('.debug', '')
            asset
          end
        end

        private
          if RUBY_VERSION >= "2.7"
            class_eval <<-RUBY, __FILE__, __LINE__ + 1
              def find_asset(path, options = {})
                @env[path, **options]
              end
            RUBY
          else
            def find_asset(path, options = {})
              @env[path, options]
            end
          end

          def precompiled?(path)
            @precompiled_asset_checker.call path
          end

          def raise_unless_precompiled_asset(path)
            raise Helper::AssetNotPrecompiledError.new(path) if @check_precompiled_asset && !precompiled?(path)
          end
      end
    end
  end
end
