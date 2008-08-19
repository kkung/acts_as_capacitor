$:.unshift "#{File.dirname(__FILE__)}/lib"
require 'acts_as_capacitor'
ActiveRecord::Base.class_eval { include ActsAsCapacitor }