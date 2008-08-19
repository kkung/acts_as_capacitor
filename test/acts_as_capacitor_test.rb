
require 'rubygems'
require 'test/unit'
require 'active_record'
require "#{File.dirname(__FILE__)}/../init"
require 'memcache'

class TestAac < ActiveRecord::Base
  
end

class TestAac < ActiveRecord::Base
  acts_as_capacitor
end

class TestAac1 < ActiveRecord::Base
  def self.table_name() "test_aacs" end
end

class ActsAsCapacitorTest < Test::Unit::TestCase
  
  def setup
    
    ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :dbfile => ":memory:")
   
    ActiveRecord::Schema.define(:version => 1) do
      create_table :test_aacs do |t|
        t.column :date, :string
        t.column :today, :integer
        t.column :created_at, :datetime      
        t.column :updated_at, :datetime
      end
    end
    
    `memcached -d -l 0.0.0.0 -p2222 -m16 -P/tmp/memcached.pid`
    sleep(0.5)
  end
  
  def teardown
    ActiveRecord::Base.connection.tables.each do |table|
      ActiveRecord::Base.connection.drop_table(table)
    end
    pid = `cat /tmp/memcached.pid`
    `kill -9 #{pid}`
    sleep(0.5)
  end
  
  # acts_as_capacitor가 제대로 설치되는지 검사
  def test_install
    
    assert_nothing_raised do 
      TestAac.new
    end
    
  end
  
  def test_cache_store_connection
    # memcached에 잘 접속하는가?
    
    t = TestAac1.new
    assert_raise(MemCache::MemCacheError) { t.cached?  }
    
    TestAac1.class_eval %q{
      acts_as_capacitor({
        :compression => true,
        :debug => false,
        :namespace => "acts_as_capacitor",
        :readonly => false,
        :urlencode => false,
        :c_threshold => 10_000,
        :servers => ["127.0.0.1:2222"]
        })
      }

    t= TestAac1.new
    assert_nothing_raised {  t.cached? }
  
  end
  
  # save하면 cache로 들어가야 한다
  def test_save_with_cache
    TestAac1.class_eval %q{
      acts_as_capacitor({
        :compression => true,
        :debug => false,
        :namespace => "acts_as_capacitor",
        :readonly => false,
        :urlencode => false,
        :c_threshold => 10_000,
        :servers => ["127.0.0.1:2222"]
        },{
          :trashold => 100
        })
    }

    t= TestAac1.new
    assert_equal false, t.cached?
    
    t.date = "20081224"
    t.save
    assert_equal true, t.cached? 
  end
  
  def test_trashold_disabled
     TestAac1.class_eval %q{
        acts_as_capacitor({
          :compression => true,
          :debug => false,
          :namespace => "acts_as_capacitor",
          :readonly => false,
          :urlencode => false,
          :c_threshold => 10_000,
          :servers => ["127.0.0.1:2222"]
          },{
            :trashold => 0
          })
    }
    
    t = TestAac1.new
    assert_equal false, t.cached?
    
    t.date = "20081224"
    t.save
    assert_equal false, t.cached?
    t.today = 2
    t.save
    assert_equal false, t.cached?
    
  end
  
  #캐쉬에서 값을 가져오는지 테스트
  def test_cache_hit
    TestAac1.class_eval %q{
      acts_as_capacitor({
        :compression => true,
        :debug => false,
        :namespace => "acts_as_capacitor",
        :readonly => false,
        :urlencode => false,
        :c_threshold => 10_000,
        :servers => ["127.0.0.1:2222"]
        },{
          :trashold => 100
        })
    }

    t= TestAac1.new
    t.date = "20081224"
    t.save
    
    assert_nothing_raised do
      t1 = t.cache_get
      assert_equal t1.created_at, t.created_at
    end

  end
  
  
  #일정량 이상이 사용되면 low level store로 저장하는지 테스트
  def test_trash_hold
    #일정량 이상이 되기 전까진 DB에 들어가면 안됨.
    TestAac1.class_eval %q{
      acts_as_capacitor({
        :compression => true,
        :debug => false,
        :namespace => "acts_as_capacitor",
        :readonly => false,
        :urlencode => false,
        :c_threshold => 10_000,
        :servers => ["127.0.0.1:2222"]
        }, {
          :trashold => 100
        })
    }
    
    t = TestAac1.new
    t.today = 0
    (1..100).each do |i|
      t.date = "20081224"
      t.today = i
      t.save
    end
    
    count = ActiveRecord::Base.connection.select_rows("select today from #{TestAac1.table_name} where id = #{t.id}")
    count = count.flatten.to_s.to_i
    
    assert_equal 1, count
    
    t.today = t.today + 1
    t.save
    
    count = ActiveRecord::Base.connection.select_rows("select today from #{TestAac1.table_name} where id = #{t.id}")
    count = count.flatten.to_s.to_i
    
    assert_equal t.today, count
    
  end

  def test_find_via_cache
   
    TestAac1.class_eval %q{
      acts_as_capacitor({
        :compression => true,
        :debug => false,
        :namespace => "acts_as_capacitor",
        :readonly => false,
        :urlencode => false,
        :c_threshold => 10_000,
        :servers => ["127.0.0.1:2222"]
        }, {
          :trashold => 100,
          :cache_field => [ 
            :date
          ]
        })
    }
    
    #normal approach..
    t = TestAac.new
    t.date = "20081224"
    t.today = "2212"
    t.save
    
    # 최초에 캐시에 없는 상태에서 가져오면,  db에서 가져오지만 바로 캐쉬 한다
    t = TestAac1.find_by_date('20081224')
    assert_equal false, t.from_cache?
    assert_equal true, t.cached?
    
    # 한번 가져왔던건.. 다시 db에서 가져오면 안댕..
    t = TestAac1.find_by_date('20081224')
    assert_equal true, t.from_cache?
    assert_equal true, t.cached?
    
  end
  
  #memcache 에 atomic 하게 increase, decrease할수있는데 이걸 활용할수있는 방법이 있을까?
  def test_atomic_inc_dec_operation
  end
  
  
end