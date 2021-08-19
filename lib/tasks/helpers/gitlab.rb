module Intrigue
  module Task
    module Gitlab
      def retrieve_gitlab_token(host)
        begin
          token = _get_task_config('gitlab_access_token')
        rescue MissingTaskConfigurationError
          _log 'Gitlab Access Token is not set in task_config.'
          _log 'Please not this means private repositories or private groups will not be retrieved.'
          return nil
        end

        token if _gitlab_token_valid?(token, host)
      end

      def group?(name, token)
        headers = { 'PRIVATE-TOKEN' => token }
        r = http_request(:get, "https://gitlab.com/api/v4/groups/#{name}", nil, headers)

        r.code == '200'
      end

      def parse_gitlab_uri(gitlab_instance)
        # example of valid gitlab uri - https://gitlab.com/superawesomegroup12345abc12345/superawesomegroup12345/projectabc

        parsed_uri = URI(gitlab_instance)
        host = "#{parsed_uri.scheme}://#{parsed_uri.host}"
        account = gitlab_instance.scan(/#{host}\/([\d\w\-\.\/]{2,255}+)\/?/i).flatten.first
        project = gitlab_instance.scan(/#{host}\/#{account}\/([\d\w\-\.]{1,255}+)/i).flatten.first

        { 'host' => host, 'account' => account, 'project' => project }
      end

      private

      def _gitlab_token_valid?(token, host)
        headers = { 'PRIVATE-TOKEN' => token }
        r = http_request(:get, "#{host}/api/v4/user", nil, headers)

        _log 'Gitlab Access Token is invalid; defaulting to unauthenticated.' if r.code == '401'
        _log 'Gitlab Access Token lacks permissions; defaulting to authenticated.' if r.code == '403'

        r.code == '200'
      end
    end
  end
end
