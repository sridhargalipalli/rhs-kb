# RHS Registration Module Knowledge Base
Version: 1.0  
Maintained by: Sridhar Galipalli  
Last updated: <add date>

---

## 1. Overview of the Registration Module
The Registration module is responsible for:
- Patient search and inquiry
- Unknown patient creation
- Quick demographics workflow
- Full new patient registration
- Patient copy workflow
- Encounter creation and management
- Registration templates
- Pending orders management
- Cross-module registration integrations (ER, Inpatient, L&D, Billing, Scheduling)

---

## 2. Patient Inquiry Screen
### 2.1 Key UI Elements
- Search bar
- Status dropdown (Active, Inactive, All)
- Patient results grid with fields:
  - Last Name
  - First Name
  - MI
  - DOB
  - Age
  - Sex
  - SSN
  - Account Number
  - Address
  - Telephone
- Actions menu (three dots)
- Generate Unknown button
- Quick Demographics button
- New Patient button

### 2.2 Behaviors
- Search supports: last name, first name, DOB, MRN, phone, SSN (if permitted)
- Clicking a row loads encounters + pending orders tabs
- Duplicate warning triggered when creating a new patient with matching identifiers

---

## 3. Patient Creation Workflows

### 3.1 Generate Unknown
Purpose: Create a temporary patient shell for ER or urgent workflows.  
Auto-populated fields:
- Placeholder last name
- Placeholder first name
- Default DOB rule (TBD)
- Temporary MRN rule (TBD)

### 3.2 Quick Demographics
Purpose: Fast creation with minimal fields.  
Required fields:
- First Name
- Last Name
- DOB
- Sex
- At least one contact method (phone/email)

### 3.3 Full New Patient
Fields captured:
- Demographics
- Address
- Contacts
- SSN
- Photo (if supported)
- Consents
- Guarantor
- Insurance

### 3.4 Copy Patient
Purpose: Use an existing patient's data as a baseline.

Rules:
- MRN is NOT copied
- SSN is NOT copied
- Address may or may not be copied (TBD)
- Emergency contacts not copied (TBD)

---

## 4. Encounter Management

### 4.1 Master Encounter
Defines an overall patient visit lineage.

Displayed as:
- “Master Encounter: <ID>”
- Expandable to show related clinical encounters.

### 4.2 Encounter Types
- Outpatient
- Inpatient
- ER
- L&D
- Newborn
- Quick Reg encounter
- Templates auto-assign type

### 4.3 Encounter Templates
Templates include:
- ER REG
- ER Registration
- General Registration
- L&D Registration
- Outpatient (L&D)
- Inpatient (Adm)
- Newborn Registration
- Testing templates

Rules:
- Templates prefill: facility, department, service type, service name
- Some fields may be locked depending on template design

---

## 5. Pending Orders
Displayed under a separate tab in the Registration screen.

Key behaviors:
- Orders may be linked to encounters by template
- Orders may require facility alignment
- Orders may require data completeness before use

---

## 6. Cross-Module Behaviors

### 6.1 ER
- ER Quick Registration launches minimal entry form
- Full registration can be completed later

### 6.2 Inpatient
- Admission may originate from provider order
- Requires consents and prior auth (if applicable)

### 6.3 L&D
- Mother → newborn linking
- Handling multiple births
- Temp naming rules

### 6.4 Billing
- Financial class assigned based on insurance
- Eligibility checks stored per encounter

---

## 7. Validation Rules (initial placeholders)
- DOB cannot be future date
- SSN format validation (if required)
- Required fields marked with (*)
- Character limits for name fields
- Address line length restrictions

---

## 8. Known Bugs / JIRA Tracking
(You will maintain this section)

Format:
- JIRA-1234 — Short description — Status — Expected fix release
- JIRA-2567 — Duplicate warning firing incorrectly — In Progress
- JIRA-3891 — Template not populating service name — Backlog

---

## 9. Future Enhancements / Ideas
(Use this section to store brainstorming)

Example:
- Add patient photo capture from web cam
- Add auto-merge suggestions for unknown patients
- Add address validation integration
- Improve template-level locking rules

---

## 10. Revision History
- v1.0 — Initial creation

