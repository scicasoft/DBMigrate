require 'sgbd_postgres'
require 'sgbd_mysql'
require 'nokogiri'

include SgbdMysql
include SgbdPostgres

def recup_sgbds
  doc = Nokogiri::Slop IO.read("infosconnexion.xml")
  tab = []
  doc.infos.sgbd.each do |sgbd|
    tab << sgbd["name"]
  end
  return tab
end

def recup_infos_base base_name
  doc = Nokogiri::Slop IO.read("infosconnexion.xml")
  tab = []
  doc.infos.sgbd.each do |sgbd|
    if sgbd["name"] == base_name
      sgbd.param.each do |p|
        tab << [p["name"], p.content]
      end
    end
  end
  return tab
end

def instancier_sgbd infos
  doc = Nokogiri::Slop IO.read("infosconnexion.xml")
  doc.infos.sgbd.each do |sgbd|
    return eval "#{sgbd['connexion']} infos" if sgbd['name'] == infos[:sgbd]
  end
  return false
end