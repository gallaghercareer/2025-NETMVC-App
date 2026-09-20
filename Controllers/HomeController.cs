using FinalProRere.ViewModels;
using FinalProReRe.Models;
using Microsoft.AspNet.Identity;
using Microsoft.AspNet.Identity.Owin;
using Microsoft.Owin.Security.Provider;
using System;
using System.Collections.Generic;
using System.Data.Entity;
using System.Linq;
using System.Web;
using System.Web.Mvc;
using System.Web.Routing;
using System.Web.UI;
using Microsoft.Owin.Security;
namespace FinalProReRe.Controllers
{
    [Authorize]
    public class HomeController : Controller
    {
        
        private ApplicationDbContext _context;

      
        public HomeController()
        {
            _context = new ApplicationDbContext();
        }
        protected override void Dispose(bool disposing)
        {
            _context.Dispose();
        }

        public ActionResult Index()
        {
            return View("EmployeeIndex"); 
        }

        #region Homepage view of all tickets
        public ActionResult EmployeeIndex()
        {
            var tickets = _context.Tickets.ToList();
           
            var viewModel = new MultipleTicketsModel()
            {
                Tickets = tickets
            };
            if (User.IsInRole("CanViewTicketsOnly"))
            {
                return View("LimitedEmployeeIndex", viewModel);
            }else
            return View(viewModel);
        }
        #endregion
        
        #region Manager has clicked Add Ticket Button  
        [HttpPost]
        public ActionResult AddTicket(Ticket ticket)
        {
            if (ModelState.IsValid) { 
            ticket.Date = DateTime.Now;

            _context.Tickets.Add(ticket);
            _context.SaveChanges();

            return RedirectToAction("EmployeeIndex");
            }
            else
            {
                IEnumerable<SelectListItem> users = _context.Users.Select(n =>
            new SelectListItem
            {
                Value = n.Id,
                Text = n.UserName
            }).ToList();

                var viewModel = new AddTicketViewModel
                {
                    ApplicationUsers = users,
                    Ticket = ticket
                };
                return View("AddTicketForm", viewModel);
            }
        }
        #endregion


        #region Manager wants to add a Ticket
        [Authorize(Roles ="CanManageTickets")]
        public ActionResult AddTicketForm()
        {
            IEnumerable<SelectListItem> users = _context.Users.Select(n =>
            new SelectListItem
            {
                Value = n.Id,
                Text = n.UserName
            }).ToList();


            var viewModel = new AddTicketViewModel()
            {
                ApplicationUsers = users
            };

            return View(viewModel);
        }
        #endregion
        

        #region Employee/Manager Wants to View a unique Ticket
        public ActionResult ViewTicket(int ticketId, string commentTextBox, string Resolved, string Username)
        {
           
            //only a manager may resolve a ticket - this action is reachable by any
            //logged in user, so the role has to be checked here and not just in the view
            if (User.IsInRole("CanManageTickets"))
            {
                if (Resolved == "true")
                {
                    var resolved_ticket = _context.Tickets.Single(t => t.Id == ticketId);

                    resolved_ticket.Resolved = true;
                    _context.SaveChanges();
                }

                if (Resolved == "false")
                {
                    var resolved_ticket = _context.Tickets.Single(t => t.Id == ticketId);

                    resolved_ticket.Resolved = false;
                    _context.SaveChanges();
                }
            };
          
            
           //if manager or employee adds a comment
            if (commentTextBox != null)
            {

                var username = User.Identity.GetUserName();


                Comment comment = new Comment()
                {
                    textBox = commentTextBox,
                    TicketId = ticketId,
                    name = username

            };
                
                _context.Comments.Add(comment);
                _context.SaveChanges();
            };
           
            //contains ticket Id
            var view_ticket = _context.Tickets.Single(t => t.Id == ticketId);

          
            var comments = _context.Comments.Where(c => c.Ticket.Id == ticketId).Include(c=>c.ApplicationUser).ToList();

          

            var viewModel = new MultipleTicketsModel()
            {
                Ticket = view_ticket,
                Comments = comments
                
            };

            if (User.IsInRole("CanViewTicketsOnly"))
            {
                return View("EmployeeViewTicket", viewModel);
            }else
                
            return View(viewModel);
        }

        #endregion

        #region Employee/Manager wants to Create a new comment
        public ActionResult NewCommentView(int Id)
        {

            var ticket = _context.Tickets.Single(t => t.Id == Id);

            var viewModel = new MultipleTicketsModel
            {
                Ticket = ticket
              
            };
           
                return View(viewModel);
        }
        #endregion

        #region manager wants to resolve/delete a ticket
        [Authorize(Roles ="CanManageTickets")]
        public ActionResult DeleteTicket(int ticketId)
        {
            var ticket = _context.Tickets.Single(t => t.Id == ticketId);

            _context.Tickets.Remove(ticket);

            _context.SaveChanges();

            return RedirectToAction("EmployeeIndex");
        }

        #endregion


    }

}