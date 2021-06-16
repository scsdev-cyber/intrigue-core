module Intrigue
  module Task
      class AwsS3BucketFindPublicObjects < BaseTask
        def self.metadata
          {
            name: 'tasks/aws_s3_find_public_objects',
            pretty_name: 'AWS S3 Find Readable Objects',
            authors: ['maxim'],
            description: 'Searches the S3 bucket for any public objects!!!!.',
            references: [],
            type: 'enrichment',
            passive: true,
            allowed_types: ['AwsS3Bucket'],
            example_entities: [
              { 'type' => 'AwsS3Bucket', 'details' => { 'name' => 'bucket-name' } }
            ],
            allowed_options: [
              { :name => 'bruteforce_found_objects', :regex => 'boolean', :default => true }
            ],
            created_types: []
          }
        end

        ### HANDLE IF OBJECT IS FOLDER

        ## Default method, subclasses must override this
        def run
          super
          require_enrichment if _get_entity_detail('region').nil?

          bucket_name = _get_entity_detail 'name'
          s3_client = initialize_s3_client bucket_name
 
          bucket_objects = retrieve_public_objects s3_client, bucket_name
          return if bucket_objects.nil?

          _log_good "Found #{bucket_objects.size} listable object(s)."

          _create_linked_issue 'aws_s3_bucket_readable', {
            proof: "#{bucket_name} lists the names of objects to any authenticated AWS user and/or everyone.",
            status: 'confirmed',
            uri: "https://#{bucket_name}.s3.amazonaws.com",
            public: true,
            details: {
              listable_objects: bucket_objects
            }
          }

          return unless _get_option('bruteforce_found_objects')

          start_task('task', @entity.project, nil, 'tasks/aws_s3_bruteforce_objects', @entity, 1, [{ 'name' => 'objects_list', 'value' => bucket_objects.join(',') }]) 
        end

        def initialize_s3_client(bucket)
          return unless _get_task_config('aws_access_key_id') && _get_task_config('aws_secret_access_key')

          region = _get_entity_detail 'region' 
          aws_access_key = _get_task_config('aws_access_key_id')
          aws_secret_key = _get_task_config('aws_secret_access_key')

          client = Aws::S3::Client.new(region: region, access_key_id: aws_access_key, secret_access_key: aws_secret_key)
          api_key_valid?(client, bucket)
        end

        def api_key_valid?(client, bucket)
          client.get_object({ bucket: bucket, key: "#{SecureRandom.uuid}.txt" })
        rescue Aws::S3::Errors::InvalidAccessKeyId, Aws::S3::Errors::SignatureDoesNotMatch
          _log_error 'AWS Access Keys are not valid; will ignore keys and use unauthenticated techniques for enrichment.'
          _set_entity_detail 'belongs_to_api_key', false # auto set to false since we are unable to check
          nil
        rescue Aws::S3::Errors::NoSuchKey
          # keys are valid, we are expecting this error
          client
        end

        def retrieve_public_objects(client, bucket)
          if _get_entity_detail 'belongs_to_api_key' # meaning bucket belongs to api key
            pub_objs_blocked = bucket_blocks_public_objects?(client, bucket)
            return if pub_objs_blocked # all public bucket objs blocked; return
          end
          # if pub objs not blocked we go the api route (auth)
          bucket_objs = retrieve_objects_via_api(client, bucket) if client
          # if the api route fails (mostly due to lack permissions/or no public objects; we'll quickly try the unauth http route)
          bucket_objs = retrieve_objects_via_http(bucket) if client.nil? || bucket_objs.nil?
          bucket_objs
        end

        def bucket_blocks_public_objects?(client, bucket)
          begin
            public_config = client.get_public_access_block(bucket: bucket)['public_access_block_configuration']
          rescue Aws::S3::Errors::AccessDenied
            _log 'permission error'
            return
          end

          ignore_acls = public_config['ignore_public_acls'] # this will be either true/false
          _log 'Bucket does not allow public objects; exiting.' if ignore_acls

          ignore_acls
        end

        def retrieve_objects_via_api(client, bucket)
          begin
            objs = client.list_objects_v2(bucket: bucket).contents.collect(&:key) # maximum of 1000 objects
          rescue Aws::S3::Errors::AccessDenied
            objs = []
            _log_error 'Could not retrieve bucket objects using the authenticated technique due to insufficient permissions.'
          end
          objs unless objs.empty? # force a nil return if an empty array as we are catching the nil reference
        end

        def retrieve_objects_via_http(bucket)
          # in this method it will try hitting the 'directory listing' and if that fails -> bruteforce common objects
          r = http_request :get, "https://#{bucket}.s3.amazonaws.com"
          if r.code != '200'
            _log 'Failed to retrieve any objects using the unauthenticated technique as bucket listing is disabled.'
            return
          end

          xml_doc = Nokogiri::XML(r.body)
          xml_doc.remove_namespaces!
          results = xml_doc.xpath('//ListBucketResult//Contents//Key').children.map(&:text)
          results[0...999] # return first 1k results as some buckets may have tons of objects
        end

        def filter_public_objects(s3_client, bucket, objs)
          public_objs = []

          if _get_entity_detail 'belongs_to_api_key'
            _log 'Running belongs to api key method'
            objs = objs.dup
            workers = (0...20).map do
              check = determine_public_object_via_acl(s3_client, bucket, objs, public_objs)
              [check]
            end
            workers.flatten.map(&:join)
          end

          ### COMBINE THESE METHODS INTO 2
          if s3_client && _get_entity_detail('belongs_to_api_key').nil?
            _log 'Running belongs authenticated method'
            objs = objs.dup
            workers = (0...20).map do
              check = determine_public_object_via_api(s3_client, bucket, objs, public_objs)
              [check]
            end
            workers.flatten.map(&:join)
          end

          if s3_client.nil? || public_objs.empty?
            _log 'Running third method'
            objs = objs.dup
            workers = (0...20).map do
              check = determine_public_object_via_http(bucket, objs, public_objs)
              [check]
              end
            workers.flatten.map(&:join)
          end

          _log "Found #{public_objs.size} public object(s) that are readable."
          _log public_objs
          public_objs
        end

        # we also need to check bucket_policy to ese if objects are listable.......

        # TEST IF NO LIST PERMISSION KEYS ARE GIVEN BUT GET ARE
        def determine_public_object_via_api(client, bucket, input_q, output_q)
          t = Thread.new do
            until input_q.empty?
              while key = input_q.shift
                begin
                  client.get_object({ bucket: bucket, key: key })
                rescue Aws::S3::Errors::AccessDenied
                  key = nil
                  return t
                  # access can be denied due to various reasons including if object is encrypted using KMS and we don't have access to the key, object ACL's, etc.
                end
                output_q << key
              end
            end
          end
          t
        end

        def determine_public_object_via_http(bucket, input_q, output_q)
          # responses = make_threaded_http_requests_from_queue(work_q, 20)
          t = Thread.new do
            until input_q.empty?
              while key = input_q.shift
                r = http_request :get, "https://#{bucket}.s3.amazonaws.com/#{key}"
                output_q << key if r.code == '200'
              end
            end
          end
          t
        end

        def determine_public_object_via_acl(client, bucket, input_q, output_q)
          acl_groups = ['http://acs.amazonaws.com/groups/global/AuthenticatedUsers', 'http://acs.amazonaws.com/groups/global/AllUsers']
          t = Thread.new do
            until input_q.empty?
              while key = input_q.shift

                begin
                  obj_acl = client.get_object_acl(bucket: bucket, key: key)
                rescue Aws::S3::Errors::AccessDenied
                  return t
                end

                obj_acl.grants.each do |grant|
                  next unless acl_groups.include? grant.grantee.uri

                  output_q << key if ['READ', 'FULL_CONTROL'].include? grant.permission
                end
              end
            end
          end
          t
        end
    end
  end
end
