## EntraSyncTool
User guide: [PDF](https://github.com/ITAutomator/EntraSyncTool/blob/main/EntraSyncTool%20Readme.pdf)  
Download: [ZIP](https://github.com/ITAutomator/EntraSyncTool/archive/refs/heads/main.zip)  
(or click the green *Code* button (above) and click *Download Zip*)   


**Overview**  
This will sync AD accounts to match Entra accounts.
![image](https://github.com/ITAutomator/EntraSyncTool/assets/135157036/c7ff7f07-3f2d-434b-852d-bdbfa239e570)


**Usage**  
This program considers Entra to be the read-only source on which AD depends.  
All changes will be made in AD only.  
  
- Missing Entra users will be added to AD  
- Extra AD users will be deleted  
- Use the CSV to provide a list of users to exclude from this  

