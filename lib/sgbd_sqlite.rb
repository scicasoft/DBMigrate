require 'sqlite3'
require 'builder'
require 'nokogiri'

module SgbdSqlite
  XML = 1
  SQLITE = 2
  Infos_connexion_sqlite = {}
  include Mysql2
  attr_accessor :client_sqlite, :infos_connexion

  def query_sqlite(req)
    return SgbdSqlite.client_sqlite.execute(req)
  end

  def connect_sqlite
    SgbdSqlite.client_mysql = SQLite3::Database.new(SgbdSqlite.infos_connexion[:file])
  end

  def recup_valeur_sqlite contenu, type, null
    contenu = contenu.gsub("'","''")
    return "NULL" if null == 'true'
    return contenu if type=='entier'
    return "'#{contenu}'"
  end

  class SgbdSqliteBase
    attr_reader :tables

    def initialize(opts = {})

      SgbdSqlite.infos_connexion = {
        :file => opts[:file]
      }

      SgbdSqlite.connect_sqlite
      recuperer_tables unless opts[:database].nil?
    end

#    def liste_base
#      bases = []
#      res = query_sqlite('show databases')
#      res.each do |row|
#        bases << row['Database']
#      end
#      return bases
#    end

#    def utiliser_base basename
#      SgbdSqlite.infos_connexion[:database] = basename
#      SgbdSqlite.connect_sqlite
#      recuperer_tables
#    end

    def recuperer_tables
      @tables = []
      l_tables = self.liste_tables
      for table_name in l_tables
        res = query_sqlite("desc `#{table_name}`")
        @tables << SgbdMysqlTable.new({:nom => table_name, :description => res})
      end
    end

    def liste_tables
      tables = []
      res = query_sqlite("SELECT name FROM sqlite_master WHERE type='table'")
      res.each do |row|
        tables << row[0]
      end
      return tables
    end

    #:source, :nom_base
    def xml_to_db infos, generer_base
      doc = Nokogiri::Slop IO.read(infos[:source])
      infos[:nom_base] ||= doc.base['nombase']
      SgbdSqlite.infos_connexion[:database] = infos[:nom_base]

      @tables = []
      doc.base.btable.each do |table|
        @tables << SgbdMysqlTable.new({:slop_table => table})
      end

      return self.import_to_db(generer_base)
    end

    def import_to_db generer_base
      puts "CREATION DE LA BASE DE DONNEES #{SgbdSqlite.infos_connexion[:database]}"
      query_sqlite "CREATE DATABASE `#{SgbdSqlite.infos_connexion[:database]}`;\n" if generer_base
      query = "CREATE DATABASE `#{SgbdSqlite.infos_connexion[:database]}`;\n\n"
      puts "CONNEXION LA BASE DE DONNEES #{SgbdSqlite.infos_connexion[:database]}"
      connect_sqlite if generer_base
      query += "USE `#{SgbdSqlite.infos_connexion[:database]}`;\n\n"
      @tables.each {|table|
        puts "CREATION DE LA TABLE #{table.nom}"
        query_sqlite table.to_sql if generer_base
        query += table.to_sql+";\n\n"
      }
      puts "VOTRE BASE DE DONN?ES EST CREEE AVEC SUCCES"
      return query
    end

    def to_sql
      sql = "CREATE DATABASE `#{SgbdSqlite.infos_connexion[:database]}`;\n"
      sql += "USE `#{SgbdSqlite.infos_connexion[:database]}`;\n"
      sql += @tables.collect{ |x| x.to_sql }.join(";\n")
      sql
    end

    def to_xml fichier
      f = File.new("#{fichier}.xml",  "w+")
      xm = Builder::XmlMarkup.new(:target=>f, :indent=>2)
      xm.instruct!
      xm.base(:nombase => SgbdSqlite.infos_connexion[:database]) { |t|
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

    def exporter_donnees_vers_xml fichier
      f = File.new("#{fichier}.xml",  "w+")
      xm = Builder::XmlMarkup.new(:target=>f, :indent=>2)
      xm.instruct!
      xm.base(:nom => SgbdSqlite.infos_connexion[:database]) { |t|
        for table in self.tables do
          res = query_sqlite "select * from `#{table.nom}`"
          if res.count != 0
            t.btable(:nom => table.nom, :taille => res.count) { |e|
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
  end

  def importer_donnees fichier, generer_base
    doc = Nokogiri::Slop IO.read(fichier)
    req = ''
    doc.base.btable.each do |table|
      puts "requete d'insertion sur la table #{table['nom']}"
      reqtab = "INSERT INTO `#{table['nom']}` VALUES \n"
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
      query_sqlite reqtab if generer_base
    end
    return req
  end

  class SgbdMysqlTable
    attr_reader :attributs
    attr_reader :nom

    def initialize opts
      unless opts[:slop_table].nil?
        slop_table = opts[:slop_table]
        @nom = slop_table['nomtable']
        @attributs = []
        if slop_table.attribut.class == Nokogiri::XML::NodeSet
          for att in slop_table.attribut
            @attributs << SgbdMysqlAttribut.new(XML, att)
          end
        else
          @attributs << SgbdMysqlAttribut.new(XML, slop_table.attribut)
        end
      end
      unless opts[:nom].nil?
        @nom = opts[:nom]
        @attributs = []
        for att in opts[:description]
          @attributs << SgbdMysqlAttribut.new(SQLITE, {
              :Field => att["Field"],
              :Type => att["Type"],
              :Null => att["Null"],
              :Key => att["Key"],
              :Default => att["Default"],
              :Extra => att["Extra"]
            })
        end
      end
    end

    def to_sql
      sql = "CREATE TABLE IF NOT EXISTS `#{@nom}` (\n\t#{@attributs.collect{ |x| x.to_sql }.join(",\n\t")})"
      sql
    end
  end

  class SgbdMysqlAttribut
    attr_accessor :nom, :type, :null, :primaire, :default, :index, :autoincrement, :taille

    #{:Field, :Type, :Null, :Key, :Default, :Extra}

    def initialize (format, opts)
      if format == SQLITE
        @nom = opts[:Field]
        @type = opts[:Type]
        @null = opts[:Null] == 'YES' ? true : false
        @primaire = opts[:Key] == 'PRI' ? true : false
        @default = opts[:Default] == 'NULL' ? nil : opts[:Default]
        @index = opts[:Key] == 'MUL' ? true : false
        @autoincrement = opts[:Extra] == 'auto_increment' ? true : false
        @taille = nil
        extraire_taille
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
        @autoincrement = opts.bautoincrement.nil? ? false : true
        begin
          @taille = opts.btaille.content
        rescue
          @taille = nil
        end
        to_mysql_type
      end
    end

    ##
    # extraction de la taille
    # affecte a la variable taille la taille de l'attribut s'il y a en
    # ensuite il enleve la taille de la variable type
    def extraire_taille
      unless (type =~ /\(/).nil? || (type =~/\)/).nil?
        self.taille = type[ (type =~ /\(/)+1 .. (type =~/\)/)-1]
        self.type = type[0..(type =~ /\(/)-1]
      end
    end

    def to_xml_type
      type_mysql_to_xml = {
        #les caracteres => CHAR, VARCHAR, TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT
        'text' => 'texte',
        'varchar' => 'chaine',
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
        'timestamp' => 'timestamp', #on update CURRENT_TIMESTAMP
        #donnees binaires (BLOB, TINYBLOB, MEDIUMBLOB, LONGBLOB)
        'blob' => 'blob',
        'tinyblob' => 'tinyblob',
        'mediumblob' => 'mediumblob',
        'longblob' => 'longblob',
        #enumerations (ENUM, SET)
        'enum' => 'enum',
        'set' => 'set'
      }

      unless type_mysql_to_xml[type].nil?
        self.type = type_mysql_to_xml[type]
      end

      if self.type == 'entiercourt' && self.taille = '1'
        self.type = 'boolean'
        self.taille = nil
      end

    end

    def to_mysql_type
      type_xml_to_mysql = {
        #les caracteres => CHAR, VARCHAR, TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT
        'texte' => 'text',
        'chaine' => 'varchar',
        'caractere' => 'char',
        'textecourt' => 'tinytext',
        'textemoyen' => 'mediumtext',
        'textelong' => 'longtext',
        #les numeriques => TINYINT, SMALLINT, MEDIUMINT, INT, INTEGER, BIGINT, FLOAT, DOUBLE, REAL, DECIMAL, NUMERIC, BIT
        'entiercourt' => 'tinyint',
        'entierpetit' => 'smallint',
        'entiermoyen' => 'mediumint',
        'entier' => 'int',
        'entierlong' => 'bigint',
        'reel' => 'float',
        'double' => 'double',
        'decimal' => 'decimal',
        'bit' => 'bit',
        #les dates et heures => DATE, DATETIME, TIME, YEAR, TIMESTAMP
        'date' => 'date',
        'dateheure' => 'datetime',
        'heure' => 'time',
        'annee' => 'year',
        'timestamp' => 'timestamp', #on update CURRENT_TIMESTAMP
        #donnees binaires (BLOB, TINYBLOB, MEDIUMBLOB, LONGBLOB)
        'blob' => 'blob',
        'tinyblob' => 'tinyblob',
        'mediumblob' => 'mediumblob',
        'longblob' => 'longblob',
        #enumerations (ENUM, SET)
        'enum' => 'enum',
        'set' => 'set'
      }

      unless type_xml_to_mysql[type].nil?
        self.type = type_xml_to_mysql[type]
      end
    end

    def to_sql
      sql = "`#{@nom}` #{@type}"
      sql += "(#{self.taille})" unless self.taille.nil?
      sql += self.null ? " NULL" : " NOT NULL"
      sql += " DEFAULT #{self.default}" unless self.default.nil?
      sql
    end

  end

end