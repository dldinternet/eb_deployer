module EbDeployer
  class Environment
    attr_reader :app, :name

    def self.unique_ebenv_name(app_name, env_name)
      raise "Environment name #{env_name} is too long, it must be under 15 chars" if env_name.size > 15
      digest = Digest::SHA1.hexdigest(app_name + '-' + env_name)[0..6]
      "#{env_name}-#{digest}"
    end

    def initialize(app, env_name, eb_driver, creation_opts={})
      @app = app
      @name = self.class.unique_ebenv_name(app, env_name)
      @bs = eb_driver
      @creation_opts = creation_opts
    end

    def deploy(version_label, settings)
      terminate if @creation_opts[:phoenix_mode]
      create_or_update_env(version_label, settings)
      smoke_test
      wait_for_env_become_healthy
    end

    def cname_prefix
      @bs.environment_cname_prefix(@app, @name)
    end

    def ==(another)
      self.app == another.app && self.name == another.name
    end

    def swap_cname_with(another)
      @bs.environment_swap_cname(self.app, self.name, another.name)
    end

    def log(msg)
      puts "[#{Time.now.utc}][beanstalk:#{@name}] #{msg}"
    end

    private

    def shorten(str, max_length, digest_length=5)
      raise "max length (#{max_length}) should be larger than digest_length (#{digest_length})" if max_length < digest_length
      return self if str.size <= max_length
      sha1 = Digest::SHA1.hexdigest(str)
      sha1[0..(digest_length - 1)] + str[(max_length - digest_length - 1)..-1]
    end

    def terminate
      if @bs.environment_exists?(@app, @name)
        with_polling_events(/terminateEnvironment completed successfully/i) do
          @bs.delete_environment(@app, @name)
        end
      end
    end

    def create_or_update_env(version_label, settings)
      if @bs.environment_exists?(@app, @name)
        with_polling_events(/Environment update completed successfully/i) do
          @bs.update_environment(@app, @name, version_label, settings)
        end
      else
        with_polling_events(/Successfully launched environment/i) do
          @bs.create_environment(@app, @name, @creation_opts[:solution_stack], @creation_opts[:cname_prefix], version_label, settings)
        end
      end
    end

    def smoke_test
      host_name = @bs.environment_cname(@app, @name)
      SmokeTest.new(@creation_opts[:smoke_test]).run(host_name, self)
    end

    def with_polling_events(terminate_pattern, &block)
      event_start_time = Time.now
      yield
      EventPoller.new(@app, @name, @bs).poll(event_start_time) do |event|
        raise event[:message] if event[:message] =~ /Failed to deploy application/

        log_event(event)
        break if event[:message] =~ terminate_pattern
      end
    end

    def wait_for_env_become_healthy
      Timeout.timeout(600) do
        current_health_status = @bs.environment_health_state(@app, @name)

        while current_health_status != 'Green'
          log("health status: #{current_health_status}")
          sleep 15
          current_health_status = @bs.environment_health_state(@app, @name)
        end

        log("health status: #{current_health_status}")
      end
    end


    def log_event(event)
      puts "[#{event[:event_date]}][beanstalk:#{@name}] #{event[:message]}"
    end
  end
end
