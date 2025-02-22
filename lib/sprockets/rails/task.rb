require 'rake'
require 'rake/sprocketstask'
require 'sprockets'
require 'action_view'

module Sprockets
  module Rails
    class Task < Rake::SprocketsTask
      attr_accessor :app

      def initialize(app = nil)
        self.app = app
        super()
      end

      def environment
        if app
          # Use initialized app.sprockets or force build an environment if
          # config.sprockets.compile is disabled
          app.sprockets || Sprockets::Railtie.build_environment(app)
        else
          super
        end
      end

      def output
        if app
          config = app.config
          File.join(config.paths['public'].first, config.sprockets.prefix)
        else
          super
        end
      end

      def sprockets
        if app
          app.config.sprockets.precompile
        else
          super
        end
      end

      def manifest
        if app
          Sprockets::Manifest.new(index, output, app.config.sprockets.manifest)
        else
          super
        end
      end

      def define
        namespace :sprockets do
          %w( environment precompile clean clobber ).each do |task|
            Rake::Task[task].clear if Rake::Task.task_defined?(task)
          end

          # Override this task change the loaded dependencies
          desc "Load asset compile environment"
          task :environment do
            # Load full Rails environment by default
            Rake::Task['environment'].invoke
          end

          desc "Compile all the sprockets named in config.sprockets.precompile"
          task :precompile => :environment do
            with_logger do
              manifest.compile(sprockets)
            end
          end

          desc "Remove old compiled sprockets"
          task :clean, [:keep] => :environment do |t, args|
            with_logger do
              manifest.clean(Integer(args.keep || self.keep))
            end
          end

          desc "Remove compiled sprockets"
          task :clobber => :environment do
            with_logger do
              manifest.clobber
            end
          end
        end
      end
    end
  end
end
