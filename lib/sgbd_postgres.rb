require 'postgres'
require 'builder'
require 'nokogiri'

module SgbdPostgres
  XML = 1
  POSTGRES = 2
  attr_accessor :client, :infos_connexion_pg

  def query_pg(req)
    return @client.exec(req)
  end

  def connect_pg
    ic = SgbdPostgres.infos_connexion_pg
    @client = PGconn.connect(ic[:host], ic[:port], '', ic[:schema], ic[:database], ic[:username], ic[:password])
  end

  def recup_valeur_pg contenu, type, null
    contenu = contenu.gsub("'","''")
    return "NULL" if null == 'true'
    return (contenu == '1' ? 'true' : 'false') if type == 'boolean'
    return contenu if type=='entier'
    return "'#{contenu}'"
  end

  class SgbdPostgresBase
    attr_reader :tables

    def initialize(opts = {})
      (opts[:database] = nil if opts[:database].empty?) unless opts[:database].nil?
      opts[:username] ||= 'root'
      opts[:password] ||= ''
      opts[:port] ||= 5432
      opts[:host] ||= 'localhost'
      opts[:database] ||= 'postgres'
      opts[:schema] ||= 'public'

      SgbdPostgres.infos_connexion_pg = {
        :username => opts[:username],
        :password => opts[:password],
        :host => opts[:host],
        :port => opts[:port].to_i,
        :database => opts[:database],
        :socket => opts[:socket],
        :schema => opts[:schema]
      }

      connect_pg
      recuperer_tables unless opts[:database].nil?
    end

    def liste_base
      bases = []
      res = query_pg('select datname from pg_database')
      res.each do |row|
        bases << row[0]
      end
      return bases
    end

    def utiliser_base basename
      SgbdPostgres.infos_connexion_pg[:database] = basename
      connect_pg
      recuperer_tables
    end

    def recuperer_tables
      @tables = []
      for table_name in self.liste_tables
        requete = <<-REQ
        SELECT
    INFORMATION_SCHEMA.COLUMNS.COLUMN_NAME,
    INFORMATION_SCHEMA.COLUMNS.DATA_TYPE,
    INFORMATION_SCHEMA.COLUMNS.IS_NULLABLE,
    INFORMATION_SCHEMA.TABLE_CONSTRAINTS.CONSTRAINT_TYPE,
    INFORMATION_SCHEMA.COLUMNS.COLUMN_DEFAULT,
    INFORMATION_SCHEMA.COLUMNS.character_maximum_length,
    INFORMATION_SCHEMA.COLUMNS.numeric_precision
FROM
    INFORMATION_SCHEMA.COLUMNS
LEFT OUTER JOIN information_schema.KEY_COLUMN_USAGE
    ON INFORMATION_SCHEMA.COLUMNS.TABLE_NAME=information_schema.KEY_COLUMN_USAGE.TABLE_NAME
        AND INFORMATION_SCHEMA.COLUMNS.COLUMN_NAME=information_schema.KEY_COLUMN_USAGE.COLUMN_NAME
LEFT OUTER JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS
    ON information_schema.KEY_COLUMN_USAGE.TABLE_NAME=information_schema.TABLE_CONSTRAINTS.TABLE_NAME
        AND information_schema.KEY_COLUMN_USAGE.CONSTRAINT_NAME=information_schema.TABLE_CONSTRAINTS.CONSTRAINT_NAME
LEFT OUTER JOIN information_schema.REFERENTIAL_CONSTRAINTS
    ON information_schema.REFERENTIAL_CONSTRAINTS.CONSTRAINT_NAME=information_schema.KEY_COLUMN_USAGE.CONSTRAINT_NAME
WHERE
    information_schema.COLUMNS.TABLE_NAME='#{table_name}' and information_schema.COLUMNS.table_catalog='#{SgbdPostgres.infos_connexion_pg[:database]}'
        REQ
        res = query_pg(requete)
        @tables << SgbdPostgresTable.new({:nom => table_name, :description => res})
      end
    end

    def liste_tables
      tables = []
      res = query_pg("SELECT tablename FROM pg_tables WHERE tablename !~ '^pg_' AND tablename !~ '^sql_'")
      res.each do |row|
        tables << row[0]
      end
      return tables
    end

    #:source, :nom_base
    def xml_to_db infos, generer_base
      doc = Nokogiri::Slop IO.read(infos[:source])
      infos[:nom_base] ||= doc.base['nombase']
      SgbdPostgres.infos_connexion_pg[:database] = infos[:nom_base]

      @tables = []
      doc.base.btable.each do |table|
        @tables << SgbdPostgresTable.new({:slop_table => table})
      end

      return self.import_to_db generer_base
    end

    def import_to_db generer_base
      puts "CREATION DE LA BASE DE DONNEES #{SgbdPostgres.infos_connexion_pg[:database]}"
      query_pg "CREATE DATABASE \"#{SgbdPostgres.infos_connexion_pg[:database]}\";\n" if generer_base
      query = "CREATE DATABASE \"#{SgbdPostgres.infos_connexion_pg[:database]}\";\n\n"
      puts "CONNEXION LA BASE DE DONNEES #{SgbdPostgres.infos_connexion_pg[:database]}"
      connect_pg if generer_base
      @tables.each {|table|
        puts "CREATION DE LA TABLE #{table.nom}"
        query_pg table.to_sql if generer_base
        query += table.to_sql+";\n\n"
      }
      puts "VOTRE BASE DE DONNEES EST CREEE AVEC SUCCES"
      return query
    end

    def to_sql
      sql = "CREATE DATABASE \"#{SgbdPostgres.infos_connexion_pg[:database]}\";\n"
      sql += "USE \"#{SgbdPostgres.infos_connexion_pg[:database]}\";\n"
      sql += @tables.collect{ |x| x.to_sql }.join(";\n")
      sql
    end

    def exporter_donnees_vers_xml fichier
      f = File.new("#{fichier}.xml",  "w+")
      xm = Builder::XmlMarkup.new(:target=>f, :indent=>2)
      xm.instruct!
      xm.base(:nom => SgbdPostgres.infos_connexion_pg[:database]) { |t|
        for table in self.tables do
          puts "exportation des donnees de la table #{table.nom}"
          res = query_pg "select * from \"#{table.nom}\""
          puts res.num_tuples
          if res.num_tuples != 0
            t.btable(:nom => table.nom, :taille => res.num_tuples) { |e|
              res.each do |row|
                e.enregistrement { |a|
                  for att in table.attributs
                    a.attribut(row[att.nom], :type => att.type, :null => row[att.nom].nil? ? true : false)
                  end
                }
              end
            }
          end
        end
      }
      f.close
    end

    def importer_donnees fichier, generer_base
      doc = Nokogiri::Slop IO.read(fichier)
      req = ''
      doc.base.btable.each do |table|
        puts "table #{table['nom']}"
        reqtab = "INSERT INTO \"#{table['nom']}\" VALUES \n"
        tabe = []
        unless table['taille'] == '1'
          table.enregistrement.each do |e|
            req1 = "("
            ats = []
            if e.attribut.class == Nokogiri::XML::NodeSet
              e.attribut.each do |atr|
                ats << recup_valeur_pg(atr.content, atr['type'], atr['null'])
              end
            else
              ats << recup_valeur_pg(e.attribut.content, e.attribut['type'], e.attribut['null'])
            end
            req1 += ats.join(",")
            req1 += ")"
            tabe << req1
          end
        else
          e = table.enregistrement
          req1 = "("
          ats = []
          if e.attribut.class == Nokogiri::XML::NodeSet
            e.attribut.each do |atr|
              ats << recup_valeur_pg(atr.content, atr['type'], atr['null'])
            end
          else
            ats << recup_valeur_pg(e.attribut.content, e.attribut['type'], e.attribut['null'])
          end
          req1 += ats.join(",")
          req1 += ")"
          tabe << req1
        end
        reqtab += tabe.join(",\n")+";"
        req += reqtab+"\n\n"
        query_pg reqtab if generer_base
      end
      return req
    end

    def to_xml fichier
      f = File.new("#{fichier}.xml",  "w+")
      xm = Builder::XmlMarkup.new(:target=>f, :indent=>2)
      xm.instruct!
      xm.base(:nombase => SgbdPostgres.infos_connexion_pg[:database]) { |t|
        for table in self.tables do
          t.btable(:nomtable => table.nom) { |a|
            for att in table.attributs
              a.attribut(:nomattribut => att.nom) { |i|
                i.btype(att.type)
                i.btaille(att.taille) unless att.taille.nil?
                i.bdefaut(att.default) unless att.default.nil?
                i.blistenum if (att.type[0..3]=='enum' || att.type[0..2] == 'set')
                att.primaire ? i.bprimaire(true) : i.bprimaire(false)
                att.null ? i.bnull(true) : i.bnull(false)
                att.autoincrement ? i.bautoincrement(true) : i.bautoincrement(false)
              }
            end
          }
        end
      }
      f.close
    end
  end

  class SgbdPostgresTable
    attr_reader :attributs
    attr_reader :nom

    def initialize opts
      unless opts[:slop_table].nil?
        slop_table = opts[:slop_table]
        @nom = slop_table['nomtable']
        @attributs = []
        if slop_table.attribut.class == Nokogiri::XML::NodeSet
          for att in slop_table.attribut
            @attributs << SgbdPostgresAttribut.new(XML, att)
          end
        else
          @attributs << SgbdPostgresAttribut.new(XML, slop_table.attribut)
        end
      end
      unless opts[:nom].nil?
        @nom = opts[:nom]
        @attributs = []
        for att in opts[:description]
          @attributs << SgbdPostgresAttribut.new(POSTGRES, {
              :Field => att["column_name"],
              :Type => att["data_type"],
              :Null => att["is_nullable"],
              :Key => att["constraint_type"],
              :Default => att["column_default"],
              :Taille => att['numeric_precision'] || att['character_maximum_length']
            })
        end
      end
    end

    def to_sql
      sql = "CREATE TABLE \"#{@nom}\" (\n\t#{@attributs.collect{ |x| x.to_sql }.join(",\n\t")}"

      cle_primaire = []
      @attributs.each do |att|
        cle_primaire << att.nom if att.primaire
      end
      sql += ", CONSTRAINT #{@nom}_pkey PRIMARY KEY (#{cle_primaire.join(',')})" unless cle_primaire.empty?
      sql += ")"
      sql
    end
  end

  class SgbdPostgresAttribut
    attr_accessor :nom, :type, :null, :primaire, :default, :index, :autoincrement, :taille

    #{:Field, :Type, :Null, :Key, :Default, :Extra}

    def initialize (format, opts)
      if format == POSTGRES
        @nom = opts[:Field]
        @type = opts[:Type]
        @null = opts[:Null] == 'YES' ? true : false
        @primaire = opts[:Key] == 'PRIMARY KEY' ? true : false
        @default = opts[:Default].nil? ? nil : (opts[:Default][0..7] != 'nextval(' ? opts[:Default] : nil)
        @index = opts[:Key] == false
        @autoincrement = opts[:Default].nil? ? false : (opts[:Default][0..7] != "nextval('" ? true : false)
        @taille = opts[:Taille]
        to_xml_type
      end
      if format == XML
        @nom = opts['nomattribut']
        @type = opts.btype.content
        @null = opts.bnull.content == 'true' ? true : false
        @primaire = opts.bprimaire.content == 'true' ? true : false
        begin
          @default = opts.bdefaut.content
        rescue
          @default = nil
        end
        @autoincrement = opts.bautoincrement.content == 'false' ? false : true
        begin
          @taille = opts.btaille.content
        rescue
          @taille = nil
        end
        to_pg_type
      end
    end

    #    ##
    #    # extraction de la taille
    #    # affecte a la variable taille la taille de l'attribut s'il y a en
    #    # ensuite il enleve la taille de la variable type
    #    def extraire_taille
    #      unless (type =~ /\(/).nil? || (type =~/\)/).nil?
    #        self.taille = type[ (type =~ /\(/)+1 .. (type =~/\)/)-1]
    #        self.type = type[0..(type =~ /\(/)-1]
    #      end
    #    end

    def to_xml_type
      type_pg_to_xml = {
        #les caracteres => CHAR, VARCHAR, TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT
        'text' => 'texte',
        'character varying' => 'chaine',
        'char' => 'caractere',
        'tinytext' => 'textecourt',
        'mediumtext' => 'textemoyen',
        'longtext' => 'textelong',
        #les numeriques => TINYINT, SMALLINT, MEDIUMINT, INT, INTEGER, BIGINT, FLOAT, DOUBLE, REAL, DECIMAL, NUMERIC, BIT
        'tinyint' => 'entiercourt',
        'smallint' => 'entierpetit',
        'mediumint' => 'entiermoyen',
        'int' => 'entier',
        'integer' => 'entier',
        'bigint' => 'entierlong',
        'float' => 'reel',
        'double' => 'double',
        'real' => 'double',
        'decimal' => 'decimal',
        'bit' => 'bit',
        #les dates et heures => DATE, DATETIME, TIME, YEAR, TIMESTAMP
        'date' => 'date',
        'datetime' => 'dateheure',
        'time' => 'heure',
        'year' => 'annee',
        'timestamp without time zone' => 'dateheure',
        'timestamp' => 'timestamp', #on update CURRENT_TIMESTAMP
        #donn?es binaires (BLOB, TINYBLOB, MEDIUMBLOB, LONGBLOB)
        'blob' => 'blob',
        'tinyblob' => 'tinyblob',
        'mediumblob' => 'mediumblob',
        'longblob' => 'longblob',
        #?num?rations (ENUM, SET)
        'enum' => 'enum',
        'set' => 'set',
        #autres
        'boolean' => 'boolean'
      }

      unless type_pg_to_xml[type].nil?
        self.type = type_pg_to_xml[type]
      end

    end

    def to_pg_type
      type_xml_to_pg = {
        #les caracteres => CHAR, VARCHAR, TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT
        'texte' => 'text',
        'chaine' => 'character varying',
        'caractere' => 'char',
        'textecourt' => 'tinytext',
        'textemoyen' => 'mediumtext',
        'textelong' => 'text',
        #les numeriques => TINYINT, SMALLINT, MEDIUMINT, INT, INTEGER, BIGINT, FLOAT, DOUBLE, REAL, DECIMAL, NUMERIC, BIT
        'entiercourt' => 'tinyint',
        'entierpetit' => 'smallint',
        'entiermoyen' => 'mediumint',
        'entier' => 'integer',
        'entierlong' => 'bigint',
        'reel' => 'float',
        'double' => 'double',
        'decimal' => 'decimal',
        'bit' => 'bit',
        #les dates et heures => DATE, DATETIME, TIME, YEAR, TIMESTAMP
        'date' => 'date',
        'dateheure' => 'timestamp without time zone',
        'heure' => 'time',
        'annee' => 'year',
        'timestamp' => 'timestamp', #on update CURRENT_TIMESTAMP
        #donn?es binaires (BLOB, TINYBLOB, MEDIUMBLOB, LONGBLOB)
        'blob' => 'blob',
        'tinyblob' => 'tinyblob',
        'mediumblob' => 'mediumblob',
        'longblob' => 'longblob',
        #?num?rations (ENUM, SET)
        'enum' => 'enum',
        'set' => 'set',
        #autres
        'boolean' => 'boolean'
      }

      unless type_xml_to_pg[type].nil?
        self.type = type_xml_to_pg[type]
      end
      
      self.type = "serial" if self.autoincrement
      self.taille = nil if self.autoincrement
    end

    def to_sql
      sql = "\"#{@nom}\" #{@type}"
      (sql += "(#{self.taille})" unless self.taille.nil?) unless self.type == 'integer'
      sql += self.null ? " NULL" : " NOT NULL"
      if self.type == 'boolean'
        sql += " DEFAULT #{self.default == '0' ? 'false' : 'true'}" unless self.default.nil?
      else
        sql += " DEFAULT #{self.default}" unless self.default.empty? unless self.default.nil?
      end
      sql
    end

  end

end

if __FILE__ == $0
  
end
