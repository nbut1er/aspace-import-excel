module LinkedObjects
  extend ActiveSupport::Concern


# This module incorporates all the classes needed to handle objects that must be linked to
# Archival Objects, such as Subjects, Top Containers, etc.

# a lot of this is adapted from Hudson Mlonglo's Arrearage plugin:
#https://github.com/hudmol/nla_staff_spreadsheet_importer/blob/master/backend/converters/arrearage_converter.rb


  class AgentHandler < Handler
    @@agents = {} 
    @@agent_relators ||= EnumList.new('linked_agent_archival_record_relators')
    AGENT_TYPES = { 'families' => 'family', 'corporate_entities' => 'corporate_entity', 'people' => 'person'}
    def self.renew
      clear(@@agent_relators)
    end
    def self.key_for(agent)
      key = "#{agent[:type]} #{agent[:header]}"
    end
    
   def self.build(row, type, num)
     relator = num ? row.fetch("#{type}_agent_relator_#{num}") :  row.fetch("#{type}_agent_relator")
     {
       :type => type,
       :id => num ? row.fetch("#{type}_agent_record_id_#{num}") :  row.fetch("#{type}_agent_record_id"),
       :name => num ? row.fetch("#{type}_agent_header_#{num}") :  row.fetch("#{type}_agent_header"),
       :relator => relator ? @@agent_relators.value(relator) : nil
     }
   end

   def self.get_or_create(row, type, num, report)
     agent = build(row, type, num)
     agent_key = key_for(agent)
     unless agent[:id].blank?
       begin
         existing_agent = JSONModel("agent_#{AGENT_TYPES[agent[:type]]}".to_sym).find(agent[:id])
      rescue Exception => e
        raise ExcelImportException.new( I18n.t('plugins.aspace-import-excel.error.no_agent', :why => e.message)) if e.message != 'RecordNotFound'
       end
     end
     begin
       if !existing_agent && !(existing_agent = @@agents.fetch(agent_key, false)) && !(existing_agent = get_db_agent(agent))
         ret_agent = create_agent(agent)
         report.add_info(I18n.t('plugins.aspace-import-excel.created', :what =>I18n.t('plugins.aspace-import-excel.agent'), :id => ret_agent.uri))
         existing_agent = ret_agent
       end
     rescue Exception => e
        raise ExcelImportException.new( I18n.t('plugins.aspace-import-excel.error.no_agent', :num => ( num ? num : ''),  :why => e.message))
     end
     agent_link = nil
     if existing_agent
       @@agents[existing_agent.id.to_s] = existing_agent
       @@agents[agent_key] = existing_agent
       agent_link = {"ref" => existing_agent.uri, "role" => 'creator'}
       agent_link["relator"] =  @@agent_relators.value(agent[:relator]) if !agent[:relator].blank?
     end
     agent_link
   end

  def self.create_agent(agent)
    begin
      ret_agent = JSONModel("agent_#{AGENT_TYPES[agent[:type]]}".to_sym).new._always_valid!
      ret_agent.names = name_obj(agent)
      ret_agent.save
    rescue Exception => e
       raise ExcelImportException.new(I18n.t('plugins.aspace-import-excel.error.no_agent', :num => (num ? num : ''), :why => e.message))
    end
    ret_agent
  end

  def self.get_db_agent(agent)
    ret_ag = nil
    if agent.id
      begin
        ret_ag = JSONModel("agent_#{agent.type}".to_sym).find(agent.id)
      rescue Exception => e
        raise ExcelImportException.new( I18n.t('plugins.aspace-import-excel.error.no_agent', :why => e.message)) if e.message != 'RecordNotFound' 
      end
    else
      a_params = {"q" => "title:\"#{agent[name]}\" AND primary_type:#{AGENT_TYPES[agent[type]]}"}
      ret_ag = search(nil, a_params, :agent, 'agents')
    end
    ret_ag
  end

   def self.name_obj(agent)
     obj = JSONModel("name_#{agent[:type]}".to_sym).new._always_valid!
     obj.source = 'ingest'
     obj.authorized = true
     obj.is_display_name = true
     if agent[:type] == 'family'
       obj.family_name = agent[:name]
     else
       obj.primary_name = agent[:name]
     end
     obj
   end
  end # agent
  class DigitalObjectHandler < Handler
    @@digital_object_types ||= EnumList.new('digital_object_digital_object_type')
    
    def self.create(row, archival_object, report)
      dig_o = nil
      dig_instance = nil
      unless !row['thumbnail'] && !row['digital_object_link']
        files = []
        if !row['digital_object_link'].blank? && row['digital_object_link'].start_with?('http')
          fv = JSONModel(:file_version).new._always_valid!
          fv.file_uri = row['digital_object_link']
          fv.publish = row['publish']
          fv.xlink_actuate_attribute = 'onRequest'
          fv.xlink_show_attribute = 'new'
          files.push fv
        end
        if !row['thumbnail'].blank? && row['thumbnail'].start_with?('http')
          fv = JSONModel(:file_version).new._always_valid!
          fv.file_uri = row['thumbnail']
          fv.publish = row['publish']
          fv.xlink_actuate_attribute = 'onLoad'
          fv.xlink_show_attribute = 'embed'
          fv.is_representative = true
          files.push fv
        end
        osn = archival_object.ref_id + 'd'
        dig_o = JSONModel(:digital_object).new._always_valid!
        dig_o.title = row['digital_object_title'].blank? ? archival_object.title : row['digital_object_title']
        dig_o.digital_object_id = osn
        dig_o.file_versions = files
        dig_o.save
        report.add_info(I18n.t('plugins.aspace-import-excel.created', :what =>I18n.t('plugins.aspace-import-excel.dig'), :id => dig_o.uri))
        dig_instance = JSONModel(:instance).new._always_valid!
        dig_instance.instance_type = 'digital_object'
        dig_instance.digital_object = {"ref" => dig_o.uri}
      end
      dig_instance
    end

    def self.renew
      clear(@@digital_object_types)
    end
  end  # DigitalObjectHandler

# one of the differences is that we don't care about location, and we do lookup against the database

  class ContainerInstanceHandler < Handler

    @@top_containers = {}
    @@container_types ||= EnumList.new('container_type')
    @@instance_types ||= EnumList.new('instance_instance_type') # for when we move instances over here


    def self.renew
      clear( @@container_types)
      clear(@@instance_types)
    end

    def self.key_for(top_container)
      key = "#{top_container[:type]}: #{top_container[:indicator]}"
      key += " #{top_container[:barcode]}" if top_container[:barcode]
      key
    end

    
    def self.build(row)
      {
        :type => @@container_types.value(row.fetch('type_1', 'Box')),
        :indicator => row.fetch('indicator_1', 'Unknown'),
        :barcode => row.fetch('barcode',nil)
      }
    end
    
    # returns a top container JSONModel
    def self.get_or_create(row, resource, report)
      top_container = build(row)
      tc_key = key_for(top_container)
#      Pry::ColorPrinter.pp " tc key: #{tc_key}"
      # check to see if we already have fetched one from the db, or created one.
      if !(existing_tc = @@top_containers.fetch(tc_key, false))
        if !(existing_tc = get_db_tc(top_container, resource))
          tc = JSONModel(:top_container).new._always_valid!
          tc.type = top_container[:type]
          tc.indicator = top_container[:indicator]
          tc.barcode = top_container[:barcode] if top_container[:barcode] 
          tc.repository = {'ref' => resource.split('/')[0..2].join('/')}
#          UpdateUtils.test_exceptions(tc,'top_container')
          tc.save
          report.add_info(I18n.t('plugins.aspace-import-excel.created', :what =>I18n.t('plugins.aspace-import-excel.tc'), :id=> tc.uri))
          @@top_containers[tc_key] = tc
          existing_tc = tc
        end
        @@top_containers[tc_key] = existing_tc
      end
      existing_tc
    end

    def self.get_db_tc(top_container, resource_uri)
      repo_idnum = resource_uri.split('/')[2]
      ret_tc = nil
      tc_str = "#{top_container[:type]} #{top_container[:indicator]}"
      tc_str += " [#{top_container[:barcode]}]" if top_container[:barcode]
      tc_params = {}
      tc_params["type[]"] = 'top_container'
      tc_params["q"] = "display_string:\"#{tc_str}\" AND collection_uri_u_sstr:\"#{resource_uri}\""
      ret_tc = search(repo_idnum,tc_params, :top_container)
      Pry::ColorPrinter.pp "FOUND NADA in the DB" if !ret_tc
      ret_tc
    end

    def self.create_container_instance(row, resource_uri,report)
      instance = nil
      if row['type']
        begin
          tc = get_or_create(row, resource_uri, report)
          sc = {'top_container' => {'ref' => tc.uri},
            'jsonmodeltype' => 'sub_container'}
          %w(2 3).each do |num|
            if row["type_#{num}"]
              sc["type_#{num}"] = @@container_types.value(row["type_#{num}"])
              sc["indicator_#{num}"] = row["indicator_#{num}"]
            end
          end
          instance = JSONModel(:instance).new._always_valid!
          instance.instance_type = @@instance_types.value(row['type'])
          instance.sub_container = JSONModel(:sub_container).from_hash(sc)
        rescue ExcelImportException => ee
          instance = nil
          raise ExcelImportException.new(I18n.t('plugins.aspace-import-excel.error.no_container_instance', :why => ee.message))
        rescue Exception => e
          msg = e.message + "\n" + e.backtrace()[0]
          instance = nil
          ExcelImportException.new(I18n.t('plugins.aspace-import-excel.error.no_container_instance', :why => msg))
        end
      end
      instance
    end

  end  # of container handler

  #shamelessly stolen (and adapted from HM's nla_staff_spreadsheet plugin :-)
  class ParentTracker
    require 'pry'
    def set_uri(hier, uri)
      @current_hierarchy ||= {}
      @current_hierarchy = Hash[@current_hierarchy.map {|k, v|
                                  if k < hier
                                    [k, v]
                                  end
                                }.compact]

      # Record the URI of the current record
      @current_hierarchy[hier] = uri
    end
    def parent_for(hier)
      # Level 1 parent may  be a resource record and therefore nil, 
      if hier > 0
        parent_level = hier - 1
        @current_hierarchy.fetch(parent_level)
      else
        nil
      end
    end
  end #of ParentTracker

  class SubjectHandler < Handler
    @@subjects = {} # will track both confirmed ids, and newly created ones.
    @@subject_term_types ||= EnumList.new('subject_term_type')
    @@subject_sources ||=  EnumList.new('subject_source')

    def self.renew
      clear(@@subject_term_types)
      clear(@@subject_sources)
    end

    def self.key_for(subject)
      key = "#{subject[:term]} #{subject[:source]}: #{subject[:type]}"
      key
    end
    def self.build(row, num)
      {
        :record_id => row.fetch("subject_#{num}_record_id"),
        :term =>  row.fetch("subject_#{num}_term"),
        :type =>   @@subject_term_types.value(row.fetch("subject_#{num}_type") || 'topical'),
        :source => @@subject_sources.value( row.fetch("subject_#{num}_source") || 'ingest')
      }
    end
 
    def self.get_or_create(row, num, repo_id, report)
      begin
        subject = build(row, num)
      rescue Exception => e
        raise ExcelImportException.new( I18n.t('plugins.aspace-import-excel.error.no_subject', :num => num,:why => e.message))
      end
      subject_key = key_for(subject)
      existing_subject = nil
      # because we might get the record id, we first look that up
      subj = nil
      unless subject[:record_id].blank?
        if !(existing_subject = @@subjects[subject[:record_id]])
          begin
            subj = JSONModel(:subject).find( subject[:record_id])
          rescue Exception => e
            raise ExcelImportException.new( I18n.t('plugins.aspace-import-excel.error.no_subject',:num => num, :why => e.message))  if e.message != 'RecordNotFound' || subject[:term].blank?
          end
          if subj
            @@subjects[subject[:record_id]] = subj
            existing_subject = subj
          end

        end
      end
      begin
        if !existing_subject && !(existing_subject = @@subjects[subject_key]) && !(existing_subject = get_db_subj(subject))
          subj = create_subj(subject)
          report.add_info(I18n.t('plugins.aspace-import-excel.created', :what =>I18n.t('plugins.aspace-import-excel.subj'), :id => subj.uri))
          existing_subject = subj
        end
      rescue Exception => e
        raise ExcelImportException.new( I18n.t('plugins.aspace-import-excel.error.no_subject',:num => num, :why => e.message))
      end
      if existing_subject
        @@subjects[existing_subject.id.to_s] = existing_subject
        @@subjects[subject_key] = existing_subject
      end
      existing_subject
    end

    def self.create_subj(subject)
      begin
        term = JSONModel(:term).new._always_valid!
        term.term =  subject[:term]
        term.term_type = subject[:type]
        term.vocabulary = '/vocabularies/1'  # we're making a gross assumption here
        subj = JSONModel(:subject).new._always_valid!
        subj.terms.push term
        subj.source = subject[:source]
        subj.vocabulary = '/vocabularies/1'  # we're making a gross assumption here
        subj.save
      rescue Exception => e
        raise ExcelImportException.new(I18n.t('plugins.aspace-import-excel.error.no_subject',:num => num, :why => e.message))
      end
      subj
    end   

    def self.get_db_subj(subject)
      s_params = {}
      s_params["q"] = "title:\"#{subject[:term]}\" AND first_term_type:#{subject[:type]}"

      ret_subj = search(nil, s_params, :subject, 'subjects')
    end


  end
end
