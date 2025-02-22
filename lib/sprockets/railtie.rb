require 'rails'
require 'rails/railtie'
require 'action_controller/railtie'
require 'active_support/core_ext/module/remove_method'
require 'active_support/core_ext/numeric/bytes'
require 'sprockets'

require 'sprockets/rails/asset_url_processor'
require 'sprockets/rails/deprecator'
require 'sprockets/rails/sourcemapping_url_processor'
require 'sprockets/rails/context'
require 'sprockets/rails/helper'
require 'sprockets/rails/quiet_sprockets'
require 'sprockets/rails/route_wrapper'
require 'sprockets/rails/version'
require 'set'

module Rails
  class Application
    # Hack: We need to remove Rails' built in config.sprockets so we can
    # do our own thing.
    class Configuration
      remove_possible_method :sprockets
    end

    # Undefine Rails' sprockets method before redefining it, to avoid warnings.
    remove_possible_method :sprockets
    remove_possible_method :sprockets=

    # Returns Sprockets::Environment for app config.
    attr_accessor :sprockets

    # Returns Sprockets::Manifest for app config.
    attr_accessor :sprockets_manifest

    # Called from asset helpers to alert you if you reference an asset URL that
    # isn't precompiled and hence won't be available in production.
    def asset_precompiled?(logical_path)
      if precompiled_sprockets.include?(logical_path)
        true
      elsif !config.cache_classes
        # Check to see if precompile list has been updated
        precompiled_sprockets(true).include?(logical_path)
      else
        false
      end
    end

    # Lazy-load the precompile list so we don't cause asset compilation at app
    # boot time, but ensure we cache the list so we don't recompute it for each
    # request or test case.
    def precompiled_sprockets(clear_cache = false)
      @precompiled_sprockets = nil if clear_cache
      @precompiled_sprockets ||= sprockets_manifest.find(config.sprockets.precompile).map(&:logical_path).to_set
    end
  end
end

module Sprockets
  class Railtie < ::Rails::Railtie
    include Sprockets::Rails::Utils

    class ManifestNeededError < StandardError
      def initialize
        msg = "Expected to find a manifest file in `app/sprockets/config/manifest.js`\n" +
        "But did not, please create this file and use it to link any sprockets that need\n" +
        "to be rendered by your app:\n\n" +
        "Example:\n" +
        "  //= link_tree ../images\n"  +
        "  //= link_directory ../javascripts .js\n" +
        "  //= link_directory ../stylesheets .css\n"  +
        "and restart your server\n\n" +
        "For more information see: https://github.com/rails/sprockets/blob/070fc01947c111d35bb4c836e9bb71962a8e0595/UPGRADING.md#manifestjs"
        super msg
      end
    end

    LOOSE_APP_ASSETS = lambda do |logical_path, filename|
      filename.start_with?(::Rails.root.join("app/sprockets").to_s) &&
      !['.js', '.css', ''].include?(File.extname(logical_path))
    end

    class OrderedOptions < ActiveSupport::OrderedOptions
      def configure(&block)
        self._blocks << block
      end
    end

    config.sprockets = OrderedOptions.new
    config.sprockets._blocks                    = []
    config.sprockets.paths                      = []
    config.sprockets.precompile                 = []
    config.sprockets.prefix                     = "/sprockets"
    config.sprockets.manifest                   = nil
    config.sprockets.quiet                      = false
    config.sprockets.resolve_sprockets_in_css_urls = true

    initializer :set_default_precompile do |app|
      if using_sprockets4?
        raise ManifestNeededError unless ::Rails.root.join("app/sprockets/config/manifest.js").exist?
        app.config.sprockets.precompile += %w( manifest.js )
      else
        app.config.sprockets.precompile += [LOOSE_APP_ASSETS, /(?:\/|\\|\A)application\.(css|js)$/]
      end
    end

    initializer :quiet_sprockets do |app|
      if app.config.sprockets.quiet
        app.middleware.insert_before ::Rails::Rack::Logger, ::Sprockets::Rails::QuietSprockets
      end
    end

    initializer :asset_url_processor do |app|
      if app.config.sprockets.resolve_sprockets_in_css_urls
        Sprockets.register_postprocessor "text/css", ::Sprockets::Rails::AssetUrlProcessor
      end
    end

    initializer :asset_sourcemap_url_processor do |app|
      Sprockets.register_postprocessor "application/javascript", ::Sprockets::Rails::SourcemappingUrlProcessor
    end

    initializer "sprockets-rails.deprecator" do |app|
      app.deprecators[:sprockets_rails] = Sprockets::Rails.deprecator if app.respond_to?(:deprecators)
    end

    config.sprockets.version     = ""
    config.sprockets.debug       = false
    config.sprockets.compile     = true
    config.sprockets.digest      = true
    config.sprockets.cache_limit = 50.megabytes
    config.sprockets.gzip        = true
    config.sprockets.check_precompiled_asset = true
    config.sprockets.unknown_asset_fallback  = true

    config.sprockets.configure do |env|
      config.sprockets.paths.each { |path| env.append_path(path) }
    end

    config.sprockets.configure do |env|
      env.context_class.send :include, ::Sprockets::Rails::Context
      env.context_class.sprockets_prefix = config.sprockets.prefix
      env.context_class.digest_sprockets = config.sprockets.digest
      env.context_class.config        = config.action_controller
    end

    config.sprockets.configure do |env|
      env.cache = Sprockets::Cache::FileStore.new(
        "#{env.root}/tmp/cache/sprockets",
        config.sprockets.cache_limit,
        env.logger
      )
    end

    Sprockets.register_dependency_resolver 'rails-env' do
      ::Rails.env.to_s
    end

    config.sprockets.configure do |env|
      env.depend_on 'rails-env'
    end

    config.sprockets.configure do |env|
      env.version = config.sprockets.version
    end

    config.sprockets.configure do |env|
      env.gzip = config.sprockets.gzip if env.respond_to?(:gzip=)
    end

    rake_tasks do |app|
      require 'sprockets/rails/task'
      Sprockets::Rails::Task.new(app)
    end

    def build_environment(app, initialized = nil)
      initialized = app.initialized? if initialized.nil?
      unless initialized
        ::Rails.logger.warn "Application uninitialized: Try calling YourApp::Application.initialize!"
      end

      env = Sprockets::Environment.new(app.root.to_s)

      config = app.config

      # Run app.sprockets.configure blocks
      config.sprockets._blocks.each do |block|
        block.call(env)
      end

      # Set compressors after the configure blocks since they can
      # define new compressors and we only accept existent compressors.
      env.js_compressor  = config.sprockets.js_compressor
      env.css_compressor = config.sprockets.css_compressor

      # No more configuration changes at this point.
      # With cache classes on, Sprockets won't check the FS when files
      # change. Preferable in production when the FS only changes on
      # deploys when the app restarts.
      if config.cache_classes
        env = env.cached
      end

      env
    end

    def self.build_manifest(app)
      config = app.config
      path = File.join(config.paths['public'].first, config.sprockets.prefix)
      Sprockets::Manifest.new(app.sprockets, path, config.sprockets.manifest)
    end

    config.after_initialize do |app|
      config = app.config

      if config.sprockets.compile
        app.sprockets = self.build_environment(app, true)
        app.routes.prepend do
          mount app.sprockets, at: config.sprockets.prefix
        end
      end

      app.sprockets_manifest = build_manifest(app)

      if config.sprockets.resolve_with.nil?
        config.sprockets.resolve_with = []
        config.sprockets.resolve_with << :manifest if config.sprockets.digest && !config.sprockets.debug
        config.sprockets.resolve_with << :environment if config.sprockets.compile
      end

      ActionDispatch::Routing::RouteWrapper.class_eval do
        class_attribute :sprockets_prefix

        prepend Sprockets::Rails::RouteWrapper

        self.sprockets_prefix = config.sprockets.prefix
      end

      ActiveSupport.on_load(:action_view) do
        include Sprockets::Rails::Helper

        # Copy relevant config to AV context
        self.debug_sprockets      = config.sprockets.debug
        self.digest_sprockets     = config.sprockets.digest
        self.sprockets_prefix     = config.sprockets.prefix
        self.sprockets_precompile = config.sprockets.precompile

        self.sprockets_environment = app.sprockets
        self.sprockets_manifest = app.sprockets_manifest

        self.resolve_sprockets_with = config.sprockets.resolve_with

        self.check_precompiled_asset = config.sprockets.check_precompiled_asset
        self.unknown_asset_fallback  = config.sprockets.unknown_asset_fallback
        # Expose the app precompiled asset check to the view
        self.precompiled_asset_checker = -> logical_path { app.asset_precompiled? logical_path }
      end
    end
  end
end
