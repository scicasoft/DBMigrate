require 'erb'
require 'sass'
require 'fonctions'

get '/style.css' do
  sass :style, :style => :expanded
end

get '/' do
  @migrations = recup_sgbds.permutation(2).to_a
  erb :index
end

post '/traitement' do
  source = params[:source]
  destination = params[:destination]
  base_dest = destination[:database]
  destination.delete("database")

  m1 = instancier_sgbd(source)
  m2 = instancier_sgbd(destination)

  m1.to_xml "schema"
  @schema_sql = m2.xml_to_db({:source => 'schema.xml', :nom_base => base_dest}, true)

  m1.exporter_donnees_vers_xml "data"
  @data_sql = m2.importer_donnees 'data.xml', true

  erb :traitement
end

get '/infos_connexion' do
  @source = params[:source] || 'mysql'
  @destination = params[:destination] || 'postgres'
  @infos_s = recup_infos_base @source
  @infos_d = recup_infos_base @destination
  erb :infos_connexion
end