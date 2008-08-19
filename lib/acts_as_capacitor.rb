module ActsAsCapacitor

  def self.included(base)
    base.extend(ClassMethods)
    base.class_eval do
      attr_accessor :from_cache
      alias_method :save_without_aac, :save
      alias_method :save, :save_without_aac
    end
  end
  
  module ClassMethods
    
    def cache_field_alias_eval(field)
      self.class_eval <<-EOS, __FILE__, __LINE__   
        def self.find_by_#{field}(*args)
          
          field_value = args.shift
        
          cache_key = nil
          if "#{field}" == "id"
            cache_key = field_value
          else
            cache_key = get_cache_ref_map("#{field}",field_value)
          end        
               
          cache_instance = cache_get(cache_key)
          if cache_key.nil? || cache_instance.nil?
            returning(find(:first, :conditions => { :#{field} => field_value }, *args)) do |instance|
              instance.cache_or_flush {}
              set_cache_ref_map("#{field}",field_value,instance.cache_id)
            end
          else
            cache_instance
          end
        end          
      EOS
    end
    
    def cache_field_alias_multiple_eval(fields)
      
      self.class_eval <<-EOS, __FILE__, __LINE__
        
        def self.find_by_#{fields.join("_with_")}(*args)
          
          cache_key = get_cache_ref_map("#{fields.join(":")}",args.join(":"))
          cache_instance = cache_get(cache_key)
          
          if cache_key.nil? || cache_instance.nil?
            returning(find(:first, :conditions => [ "#{fields.join(" = ? AND ")} = ? ", *args ])) do |instance|
              instance.cache_or_flush {}
              set_cache_ref_map("#{fields.join(":")}",args.join(":"),instance.cache_id)
            end
          else
            cache_instance
          end
          
        end  
        
      EOS
    end
    
    def cache_field_alias(fields)
      fields.each do |field|
        if field.kind_of?(Array)
          field.each { |f| cache_field_alias_eval(f) }
          cache_field_alias_multiple_eval(field)
          
        else
          cache_field_alias_eval(field)
        end
      end    
    end
    
    def acts_as_capacitor(memcache_config = {}, options = {})
      include InstanceMethods
      @@aac_options = options
      
      options[:cache_field] = [] if options[:cache_field].nil?
      options[:cache_field] << 'id' if !options[:cache_field].include?(:id)
      
      cache_field_alias(options[:cache_field])
      
      silence_warnings do
        servers = memcache_config.delete(:servers)
        Object.const_set(:AAC_CACHE, MemCache::new(memcache_config))
        AAC_CACHE.servers = servers if servers
      end
      
    end
    
    def cache_get(key)
    
      instance = autoload_missing_constants do
        AAC_CACHE.get aac_cache_key(key)
      end
      
      instance.from_cache = true unless instance.nil?
      return instance
      
    end
    
    def cache_put(key,inst)
      returning(inst) do |v|
        AAC_CACHE.set(aac_cache_key(key), v) unless v.nil?
      end
    end
    
    def delete_cache(key)
      AAC_CACHE.delete(aac_cache_key(key))
    end
    
    def cached?(key)
      cache_get(key).nil? ? false : true
    end
    
    def autoload_missing_constants
      yield
    rescue ArgumentError, MemCache::MemCacheError => error
      lazy_load ||= Hash.new { |hash, hash_key| hash[hash_key] = true; false }
      if error.to_s[/undefined class|referred/] && !lazy_load[error.to_s.split.last.constantize] then retry
      else raise error end
    end

    def cache_name
      @cache_name ||= respond_to?(:base_class) ? base_class.name : name
    end

    def aac_cache_key(key)    
      [cache_name,key].compact.join(':').gsub(' ','_')
    end
    
    def cache_or_flush(key,instance)
      capacitor = AAC_CACHE.get("capacitor_#{self.name}") || {}
      if capacitor[key].nil?
        capacitor[key] = {:refcount => 0}
      end
  
      if capacitor[key][:refcount].to_i >= @@aac_options[:trashold].to_i
        capacitor[key][:refcount] = 0
        yield
      else
        capacitor[key][:refcount] = capacitor[key][:refcount] + 1
        cache_put(key,instance)
      end
      
      capacitor[key][:cached_at] = Time.now
      
      AAC_CACHE.set("capacitor_#{self.name}", capacitor)
      return instance
    end
    
    def has_key_on_cache_ref_map(field,field_value)
      get_cache_ref_map(field,field_value).nil? ? false : true
    end
    
    def get_cache_ref_map(field,field_value)
      map = AAC_CACHE.get("aac_cache_ref_map_#{self.name}") || {}    
      return map[field] && map[field][field_value]
    end
    
    def set_cache_ref_map(field,field_value,ref_key)
      map = AAC_CACHE.get("aac_cache_ref_map_#{self.name}") || {}    
      map[field] = {} if map[field].nil?  
      map[field][field_value] = ref_key
    
      AAC_CACHE.set("aac_cache_ref_map_#{self.name}",map)
    end
    
    def flush_caches(use_ttl)
      capacitor = AAC_CACHE.get("capacitor_#{self.name}") || {}
      
      flushs = []
      capacitor.each_key do |key|
        if use_ttl &&  @@aac_options[:ttl] > 0
          flushs << key  if (( Time.now - capacitor[key][:cached_at]) > @@aac_options[:ttl] )
        else
          flushs << key
        end
      end
      
      flushs.each { |flush| 
        cache_get(flush).save(:force_flush) rescue nil
        capacitor[flush] = nil  
        delete_cache(flush)
      }
      
      AAC_CACHE.set("capacitor_#{self.name}", capacitor)
      
    end
    
  end
  
  module InstanceMethods
    
    def cache_get
      self.class.cache_get(cache_id)
    end
    
    def cache_put
      self.class.cache_put(cache_id, self)
    end
    
    def cache_id
      "#{id}"
    end
    
    def cached?
      self.class.cached? cache_id
    end
    alias :is_cached? :cached?
    
    def cache_or_flush(&block)
      self.class.cache_or_flush(cache_id,self,&block)
    end
    
    def from_cache?
      @from_cache || false
    end
    
    def save(*args)
      
      force_flush = args.delete(:force_flush)
      
      save_proc = proc do
        perform_validation = args.first rescue nil

        result = unless perform_validation.nil?
          save_without_aac(perform_validation)
        else
          save_without_aac
        end
      end
      
      if force_flush || self.new_record?
        save_proc.call
      end
      cache_or_flush(&save_proc)
      
    end
    
  end
  
end