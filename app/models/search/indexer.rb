# ES UPGRADE TRANSITION #
# Change all instances of $new_elasticsearch to $elasticsearch
class Indexer

  BATCH_SIZE = 1000
  INDEXERS_FOR_CLASS = {
    "Work" => %w(WorkIndexer BookmarkedWorkIndexer),
    "Bookmark" => %w(BookmarkIndexer),
    "Tag" => %w(TagIndexer),
    "Pseud" => %w(PseudIndexer),
    "Series" => %w(BookmarkedSeriesIndexer),
    "ExternalWork" => %w(BookmarkedExternalWorkIndexer)
  }.freeze

  delegate :klass, :index_name, :document_type, to: :class

  ##################
  # CLASS METHODS
  ##################

  def self.klass
    raise "Must be defined in subclass"
  end

  # Originally added to allow IndexSweeper to find the Elasticsearch document
  # ids when they do not match the associated ActiveRecord objects' ids.
  #
  # Override in subclasses if necessary.
  def self.find_elasticsearch_ids(ids)
    ids
  end

  def self.delete_index
    if $new_elasticsearch.indices.exists(index: index_name)
      $new_elasticsearch.indices.delete(index: index_name)
    end
  end

  def self.create_index
    $new_elasticsearch.indices.create(
      index: index_name,
      body: {
        settings: {
          index: {
            number_of_shards: 5,
          }
        },
        mappings: mapping,
      }
    )
  end

  # Note that the index must exist before you can set the mapping
  def self.create_mapping
    $new_elasticsearch.indices.put_mapping(
      index: index_name,
      type: document_type,
      body: mapping
    )
  end

  def self.mapping
    {
      document_type => {
        properties: {
          #add properties in subclasses
        }
      }
    }
  end

  def self.index_all(options={})
    unless options[:skip_delete]
      delete_index
      create_index
    end
    index_from_db
  end

  def self.index_from_db
    total = (indexables.count / BATCH_SIZE) + 1
    i = 1
    indexables.find_in_batches(batch_size: BATCH_SIZE) do |group|
      puts "Queueing #{klass} batch #{i} of #{total}"
      AsyncIndexer.new(self, :world).enqueue_ids(group.map(&:id))
      i += 1
    end
  end

  # Add conditions here
  def self.indexables
    Rails.logger.info "Blueshirt: Logging use of constantize class self.indexables #{klass}"
    klass.constantize
  end

  def self.index_name
    "ao3_#{Rails.env}_#{klass.underscore.pluralize}"
  end

  def self.document_type
    klass.underscore
  end

  # Given a searchable object, what indexers should handle it?
  # Returns an array of indexers
  def self.for_object(object)
    name = object.is_a?(Tag) ? 'Tag' : object.class.to_s
    (INDEXERS_FOR_CLASS[name] || []).map(&:constantize)
  end

  # Should be called after a batch update, with the IDs that were successfully
  # updated. Calls successful_reindex on the indexable class.
  def self.handle_success(ids)
    if indexables.respond_to?(:successful_reindex)
      indexables.successful_reindex(ids)
    end
  end

  ####################
  # INSTANCE METHODS
  ####################

  attr_reader :ids

  def initialize(ids)
    @ids = ids
  end

  def objects
    Rails.logger.info "Blueshirt: Logging use of constantize class objects #{klass}"
    @objects ||= klass.constantize.where(id: ids).inject({}) do |h, obj|
      h.merge(obj.id => obj)
    end
  end

  def batch
    @batch = []
    ids.each do |id|
      object = objects[id.to_i]
      if object.present?
        @batch << { index: routing_info(id) }
        @batch << document(object)
      else
        @batch << { delete: routing_info(id) }
      end
    end
    @batch
  end

  def index_documents
    $new_elasticsearch.bulk(body: batch)
  end

  def index_document(object)
    info = {
      index: index_name,
      type: document_type,
      id: document_id(object.id),
      body: document(object)
    }
    if respond_to?(:parent_id)
      info.merge!(routing: parent_id(object.id, object))
    end
    $new_elasticsearch.index(info)
  end

  def routing_info(id)
    {
      '_index' => index_name,
      '_type' => document_type,
      '_id' => id
    }
  end

  def document(object)
    object.as_json(root: false)
  end

  # can be overriden by our bookmarkable indexers
  def document_id(id)
    id
  end

end
