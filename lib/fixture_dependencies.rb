class FixtureDependencies
  @fixtures = {}
  @loaded = {}
  @verbose = 0
  
  # Load all record arguments into the database. If a single argument is
  # given and it corresponds to a single fixture, return the the model
  # instance corresponding to that fixture.  If a single argument if given
  # and it corresponds to a model, return all model instances corresponding
  # to that model.  If multiple arguments are given, return a list of
  # model instances (for single fixture arguments) or list of model instances
  # (for model fixture arguments).  If no arguments, return the empty list.
  #
  # This will load the data from the yaml files for each argument whose model
  # is not already in the fixture hash.
  def self.load(*records)
    ret = records.collect do |record| 
      model_name, name = split_name(record)
      if name
        use(record.to_sym)
      else
        model_name = model_name.singularize
        unless loaded[model_name.to_sym]
          puts "loading #{model_name}.yml" if verbose > 0
          load_yaml(model_name) 
        end
        fixtures[model_name.to_sym].keys.collect{|name| use("#{model_name}__#{name}".to_sym)}
      end
    end
    records.length == 1 ? ret[0] : ret
  end
end

require 'fixture_dependencies/active_record' if defined?(ActiveRecord::Base)
require 'fixture_dependencies/sequel' if defined?(Sequel::Model)
  

class << FixtureDependencies
  attr_reader :fixtures, :loaded
  attr_accessor :verbose, :fixture_path
  
  private
    
  # Add a fixture to the fixture hash (does not add to the database,
  # just makes it available to be add to the database via use).
  def add(model_name, name, attributes)
    (fixtures[model_name.to_sym]||={})[name.to_sym] = attributes
  end
  
  # Get the model instance that already exists in the database using
  # the fixture name.  
  def get(record)
    model_name, name = split_name(record)
    model = model_name.camelize.constantize
    model_method(:model_find, model_type(model), model, fixtures[model_name.to_sym][name.to_sym][model.primary_key.to_sym])
  end
  
  # Adds all fixtures in the yaml fixture file for the model to the fixtures
  # hash (does not add them to the database, see add).
  def load_yaml(model_name)
    raise(ArgumentError, "No fixture_path set. Use FixtureDependencies.fixture_path = ...") unless fixture_path
    YAML.load(File.read(File.join(fixture_path, "#{model_name.camelize.constantize.table_name}.yml"))).each do |name, attributes|
      symbol_attrs = {}
      attributes.each{|k,v| symbol_attrs[k.to_sym] = v}
      add(model_name.to_sym, name, symbol_attrs)
    end
    loaded[model_name.to_sym] = true
  end
  
  # Delegate to the correct method based on mtype
  def model_method(meth, mtype, *args, &block)
    send("#{meth}_#{mtype}", *args, &block)
  end
  
  # A symbol representing the base class of the model, currently
  # ActiveRecord::Base and Sequel::Model are supported.
  def model_type(model)
    if model.ancestors.map{|x| x.to_s}.include?('ActiveRecord::Base')
      :AR
    elsif model.ancestors.map{|x| x.to_s}.include?('Sequel::Model')
      :S
    else
      raise TypeError, 'not ActiveRecord or Sequel model'
    end
  end
  
  # Split the fixture name into the name of the model and the name of
  # the individual fixture.
  def split_name(name)
    name.to_s.split('__', 2)
  end
  
  # Load the individual fixture into the database, by loading all necessary
  # belongs_to dependencies before saving the model, and all has_*
  # dependencies after saving the model.  If the model already exists in
  # the database, return it.  Will check the yaml file for fixtures if no
  # fixtures yet exist for the model.  If the fixture isn't in the fixture
  # hash, raise an error.
  def use(record, loading = [], procs = {})
    spaces = " " * loading.length
    puts "#{spaces}using #{record}" if verbose > 0
    puts "#{spaces}load stack:#{loading.inspect}" if verbose > 1
    loading.push(record)
    model_name, name = split_name(record)
    model = model_name.camelize.constantize
    unless loaded[model_name.to_sym]
      puts "#{spaces}loading #{model.table_name}.yml" if verbose > 0
      load_yaml(model_name) 
    end
    mtype = model_type(model)
    model_method(:raise_model_error, mtype, "Couldn't use fixture #{record.inspect}") unless attributes = fixtures[model_name.to_sym][name.to_sym]
    # return if object has already been loaded into the database
    if existing_obj = model_method(:model_find_by_pk, mtype, model, attributes[model.primary_key.to_sym])
      puts "#{spaces}using #{record}: already in database" if verbose > 2
      return existing_obj
    end
    obj = model.new
    many_associations = []
    attributes.each do |attr, value|
      if reflection = model_method(:reflection, mtype, model, attr.to_sym)
        if [:belongs_to, :many_to_one].include?(model_method(:reflection_type, mtype, reflection))
          dep_name = "#{model_method(:reflection_class, mtype, reflection).name.underscore}__#{value}".to_sym
          if dep_name == record
            # Self referential record, use primary key
            puts "#{spaces}#{record}.#{attr}: belongs_to self-referential" if verbose > 1
            attr = model_method(:reflection_key, mtype, reflection)
            value = attributes[model.primary_key.to_sym]
          elsif loading.include?(dep_name)
            # Association cycle detected, set foreign key for this model afterward using procs
            # This is will fail if the column is set to not null or validates_presence_of
            puts "#{spaces}#{record}.#{attr}: belongs-to cycle detected:#{dep_name}" if verbose > 1
            (procs[dep_name] ||= []) << Proc.new do |assoc|
              m = model_method(:model_find, mtype, model, attributes[model.primary_key.to_sym])
              m.send("#{attr}=", assoc)
              model_method(:model_save, mtype, m)
            end
            value = nil
          else
            # Regular assocation, load it
            puts "#{spaces}#{record}.#{attr}: belongs_to:#{dep_name}" if verbose > 1
            use(dep_name, loading, procs)
            value = get(dep_name)
          end
        elsif
          many_associations << [attr, reflection, model_method(:reflection_type, mtype, reflection) == :has_one ? [value] : value]
          next
        end
      end
      puts "#{spaces}#{record}.#{attr} = #{value.inspect}" if verbose > 2
      obj.send("#{attr}=", value)
    end

    puts "#{spaces}saving #{record}" if verbose > 1

    model_method(:model_save, mtype, obj)
    # after saving the model, we set the primary key within the fixture hash, in case it was not explicitly specified in the fixture and was generated by an auto_increment / serial field
    fixtures[model_name.to_sym][name.to_sym][model.primary_key.to_sym] ||= obj[model.primary_key.to_sym]

    loading.pop
    # Update the circular references 
    if procs[record]
      procs[record].each{|p| p.call(obj)} 
      procs.delete(record)
    end
    # Update the has_many and habtm associations
    many_associations.each do |attr, reflection, values|
      values.each do |value|
        dep_name = "#{model_method(:reflection_class, mtype, reflection).name.underscore}__#{value}".to_sym
        rtype = model_method(:reflection_type, mtype, reflection) if verbose > 1
        if dep_name == record
          # Self referential, add association
          puts "#{spaces}#{record}.#{attr}: #{rtype} self-referential" if verbose > 1
          model_method(:add_associated_object, mtype, reflection, attr, obj, obj)
        elsif loading.include?(dep_name)
          # Cycle Detected, add association to this object after saving other object
          puts "#{spaces}#{record}.#{attr}: #{rtype} cycle detected:#{dep_name}" if verbose > 1
          (procs[dep_name] ||= []) << Proc.new do |assoc|
            model_method(:add_associated_object, mtype, reflection, attr, obj, assoc)
          end
        else
          # Regular association, add it
          puts "#{spaces}#{record}.#{attr}: #{rtype}:#{dep_name}" if verbose > 1
          model_method(:add_associated_object, mtype, reflection, attr, obj, use(dep_name, loading, procs))
        end
      end
    end
    obj
  end
end
