using SocialDummySimulation

SocialDummySimulation.loadData() 

# This could return a list of elemantry ABMs (ABMsList) 
(towns,houses,population) =
    SocialDummySimulation.initDummyABMs() 

# Create a MultiABM 
# 
# After a Multi ABM has been initialized run the simulation 
# e.g.
# createMultiABM(ABMsList) 
# 
SocialDummySimulation.runDummyExample(population)