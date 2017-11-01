admin = db.getSiblingDB("admin")

admin.grantRolesToUser( "username", [ "root" , { role: "root", db: "admin" } ] )
