class IndexQueue

  BATCH_SIZE = 1000
  REDIS = REDIS_GENERAL

  ##################
  # CLASS METHODS
  ##################

  def self.all
    REDIS.keys("index:*")
  end

  def self.get_key(klass, label)
    "index:#{klass.to_s.underscore}:#{label}"
  end

  def self.enqueue(object, label)
    klass = object.is_a?(Tag) ? 'Tag' : object.class.to_s
    enqueue_id(klass, object.id, label)
  end

  def self.enqueue_id(klass, id, label)
    key = get_key(klass, label)
    new(key).add_id(id)
  end

  def self.enqueue_ids(klass, ids, label)
    key = get_key(klass, label)
    new(key).add_ids(ids)
  end

  ####################
  # INSTANCE METHODS
  ####################

  attr_reader :name

  def initialize(name)
    @name = name
    @old_name = name
  end

  def add_id(id)
    REDIS.sadd(name, id)
  end

  def add_ids(ids)
    REDIS.sadd(name, ids) unless ids.blank?
  end

  def run
    return unless exists?
    rename
    create_subqueues
    delete
  end

  def ids
    @ids = REDIS.smembers(name)
  end  

  private

  def exists?
    REDIS.exists(name)
  end

  def rename
    @name = "#{name}:#{Time.now.to_i}"
    REDIS.rename(@old_name, @name)
  end

  def create_subqueues
    _, klass, label = name.split(":")
    klass = klass.classify # convert to the uppercase version

    ids.in_groups_of(BATCH_SIZE, false).each_with_index do |id_batch, i|
      if $rollout.active?(:start_new_indexing)
        AsyncIndexer.index(klass, id_batch, label)
      end

      # After the ES6 upgrade, delete this whole unless block.
      unless $rollout.active?(:stop_old_indexing)
        if %w(Work Bookmark Pseud StatCounter Tag).include?(klass)
          IndexSubqueue.create_and_enqueue("#{name}:#{i}", id_batch)
        end
      end
    end
  end

  def delete
    REDIS.del(name)
  end

end
